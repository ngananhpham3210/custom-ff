import asyncio
import io
import os
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from typing import Any, List, Optional, NamedTuple

import av
import aiohttp
import psutil
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, HttpUrl

# =============================================================================
# Configuration & Models
# =============================================================================

CODEC_MAP = {"opus": "webm", "aac": "mp4", "mp3": "mp3", "vorbis": "ogg"}

class StreamRequest(BaseModel):
    url: HttpUrl
    cookies: str
    po_token: str
    provider: str = "deepgram"  # "deepgram" or "assemblyai"
    chunk_duration: int = 1800   # 30 minutes
    buffer_tail: int = 600      # 10 minutes (overlap check)

class Cargo(NamedTuple):
    buffer: io.BytesIO
    index: int
    mime_type: str
    size_mb: float

# =============================================================================
# Utility Functions
# =============================================================================

def get_runtime_paths():
    """Locate Deno and other runtimes."""
    cwd = os.getcwd()
    return {
        "deno": [
            os.path.join(cwd, "bin/deno"), # Local install from your script
            "/var/task/bin/deno",          # Vercel task path
            "/usr/local/bin/deno",
            os.path.expanduser("~/.deno/bin/deno"),
        ]
    }

def find_deno():
    paths = get_runtime_paths()["deno"]
    for path in paths:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None

def miner_log_monitor(pipe):
    """Beautifies yt-dlp stderr logs."""
    for line in iter(pipe.readline, b""):
        text = line.decode("utf-8", errors="ignore")
        if "[download]" in text:
            text = text.replace("[download]", "[MINER] ⛏️ ")
        elif "[youtube]" in text:
            text = text.replace("[youtube]", "[MINER] 🔎 ")
        sys.stderr.write(text)
        sys.stderr.flush()

# =============================================================================
# Core PyAV Processing (CPU Bound)
# =============================================================================

def create_package(packets: List[av.Packet], input_stream, max_dur: float, fmt: str):
    """Seals raw audio packets into a memory-resident container."""
    output_mem = io.BytesIO()
    with av.open(output_mem, mode="w", format=fmt) as container:
        stream = container.add_stream(input_stream.codec_context.name)
        stream.time_base = input_stream.time_base
        if input_stream.codec_context.extradata:
            stream.codec_context.extradata = input_stream.codec_context.extradata

        base_dts = packets[0].dts
        base_pts = packets[0].pts
        cutoff_idx = 0

        for i, pkt in enumerate(packets):
            rel_time = float(pkt.dts - base_dts) * input_stream.time_base
            if rel_time < max_dur:
                pkt.dts -= base_dts
                pkt.pts -= base_pts
                pkt.stream = stream
                container.mux(pkt)
                cutoff_idx = i
            else:
                break

    output_mem.seek(0)
    size = round(output_mem.getbuffer().nbytes / 1024 / 1024, 2)
    return output_mem, cutoff_idx, size

def run_packager(loop, conveyor_belt, req: StreamRequest, cookie_path: str):
    """The 'Miner' - Streams from yt-dlp and chunks via PyAV."""
    deno_path = find_deno()
    
    cmd = [
        sys.executable, "-m", "yt_dlp",
        "-f", "ba",
        "-S", "+abr,+tbr,+size",
        "--cookies", cookie_path,
        "--http-chunk-size", "10M",
        "--extractor-args", f"youtube:player_client=tv;playback_wait=2;po_token={req.po_token}",
        "-o", "-",
        str(req.url)
    ]

    # Add Deno support if found
    if deno_path:
        cmd.extend(["--js-runtimes", f"deno:{deno_path}", "--remote-components", "ejs:npm"])
        print(f"[PACKAGER] 🚀 Using Deno at: {deno_path}")

    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    log_thread = threading.Thread(target=miner_log_monitor, args=(process.stderr,))
    log_thread.daemon = True
    log_thread.start()

    try:
        in_container = av.open(process.stdout, mode="r")
        in_stream = in_container.streams.audio[0]
        codec = in_stream.codec_context.name
        out_fmt = CODEC_MAP.get(codec, "matroska")
        mime = f"audio/{out_fmt}"

        buffer: List[av.Packet] = []
        box_id = 0
        threshold = req.chunk_duration + req.buffer_tail

        for packet in in_container.demux(in_stream):
            if packet.dts is None: continue
            buffer.append(packet)
            
            curr_dur = float(packet.dts - buffer[0].dts) * in_stream.time_base
            if curr_dur >= threshold:
                mem_file, cutoff, size = create_package(buffer, in_stream, req.chunk_duration, out_fmt)
                cargo = Cargo(mem_file, box_id, mime, size)
                asyncio.run_coroutine_threadsafe(conveyor_belt.put(cargo), loop)
                buffer = buffer[cutoff + 1:]
                box_id += 1

        if buffer:
            mem_file, _, size = create_package(buffer, in_stream, float("inf"), out_fmt)
            cargo = Cargo(mem_file, box_id, mime, size)
            asyncio.run_coroutine_threadsafe(conveyor_belt.put(cargo), loop)

    except Exception as e:
        print(f"[PACKAGER ERROR] {e}")
    finally:
        process.kill()
        asyncio.run_coroutine_threadsafe(conveyor_belt.put(None), loop)

# =============================================================================
# Async Shipper (I/O Bound)
# =============================================================================

async def ship_cargo(session: aiohttp.ClientSession, cargo: Cargo, provider: str, results: list):
    """Uploads the chunk to the selected provider."""
    if provider == "assemblyai":
        url = "https://api.assemblyai.com/v2/upload"
        key = os.getenv("ASSEMBLYAI_KEY", "193053bc6ff84ba9aac2465506f47d48")
        headers = {"Authorization": key, "Content-Type": "application/octet-stream"}
    else:
        url = "https://manage.deepgram.com/storage/assets"
        key = os.getenv("DEEPGRAM_KEY", "d6bf3bf38250b6370e424a0805f6ef915ae00bec")
        headers = {"Authorization": f"Token {key}", "Content-Type": cargo.mime_type}

    try:
        async with session.post(url, headers=headers, data=cargo.buffer) as resp:
            body = await resp.json()
            if resp.status >= 400:
                print(f"[SHIPPER] ❌ Failed Box #{cargo.index}: {resp.status}")
                return

            ref = body.get("upload_url") if provider == "assemblyai" else (body.get("asset_id") or body.get("asset"))
            print(f"[SHIPPER] ✅ Delivered Box #{cargo.index} | {cargo.size_mb}MB | Ref: {ref}")
            results.append({"index": cargo.index, "ref": ref, "size_mb": cargo.size_mb})
    except Exception as e:
        print(f"[SHIPPER] ⚠️ Error Box #{cargo.index}: {e}")
    finally:
        cargo.buffer.close()

async def run_shipper(conveyor_belt: asyncio.Queue, provider: str, results: list):
    async with aiohttp.ClientSession() as session:
        tasks = []
        while True:
            cargo = await conveyor_belt.get()
            if cargo is None: break
            tasks.append(asyncio.create_task(ship_cargo(session, cargo, provider, results)))
        if tasks:
            await asyncio.gather(*tasks)

# =============================================================================
# FastAPI Application
# =============================================================================

app = FastAPI(title="yt-dlp PyAV Streamer")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
async def health():
    return {
        "status": "online",
        "deno": find_deno(),
        "memory": psutil.virtual_memory().percent
    }

@app.post("/")
async def process_video(req: StreamRequest):
    loop = asyncio.get_running_loop()
    conveyor_belt = asyncio.Queue()
    results = []
    
    # Create temp cookie file
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as tf:
        tf.write(req.cookies)
        cookie_path = tf.name

    start_time = time.time()
    
    try:
        # Start Shipper
        shipper_task = asyncio.create_task(run_shipper(conveyor_belt, req.provider, results))
        
        # Run Packager in a separate thread (it's CPU bound and blocks)
        await loop.run_in_executor(None, run_packager, loop, conveyor_belt, req, cookie_path)
        
        # Wait for all uploads to finish
        await shipper_task
        
        return {
            "success": True,
            "provider": req.provider,
            "duration_seconds": round(time.time() - start_time, 2),
            "chunks": sorted(results, key=lambda x: x['index'])
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if os.path.exists(cookie_path):
            os.remove(cookie_path)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
