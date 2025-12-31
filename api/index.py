import asyncio
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from typing import Any, List, Optional, NamedTuple
from concurrent.futures import ThreadPoolExecutor

import av
import aiohttp
import psutil
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, HttpUrl

# =============================================================================
# Configuration & Data Structures
# =============================================================================

@dataclass
class GlobalConfig:
    CHUNK_DURATION: int = 1800  # 30 mins
    BUFFER_TAIL: int = 600      # 10 mins
    RUNTIME_PATHS: dict = field(default_factory=lambda: {
        "deno": [
            "./bin/deno", # Local path from your install script
            "/var/task/bin/deno",
            "/vercel/.deno/bin/deno",
            os.path.expanduser("~/.deno/bin/deno"),
            "/usr/local/bin/deno",
        ],
    })
    CODEC_MAP: dict = field(default_factory=lambda: {
        "opus": "webm", 
        "aac": "mp4", 
        "mp3": "mp3", 
        "vorbis": "ogg"
    })

CONFIG = GlobalConfig()

class Cargo(NamedTuple):
    buffer: io.BytesIO
    index: int
    mime_type: str
    size_mb: float

class StreamRequest(BaseModel):
    url: HttpUrl
    cookies: str
    po_token: str
    provider: str = "assemblyai" # "deepgram" or "assemblyai"
    api_key: Optional[str] = None
    yt_dlp_options: dict = {}

# =============================================================================
# Deno & Environment Detection
# =============================================================================

def run_command(cmd: list[str], timeout: int = 5) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

def find_deno_runtime() -> Optional[str]:
    for path in CONFIG.RUNTIME_PATHS["deno"]:
        try:
            if subprocess.run([path, "--version"], capture_output=True).returncode == 0:
                return path
        except:
            continue
    return None

def get_versions():
    return {
        "yt_dlp": run_command([sys.executable, "-m", "yt_dlp", "--version"]).stdout.strip() or "unknown",
        "ffmpeg": run_command(["ffmpeg", "-version"]).stdout.split('\n')[0] or "unknown",
        "deno": find_deno_runtime()
    }

# =============================================================================
# Logistics: Packager (PyAV)
# =============================================================================

def miner_log_monitor(pipe):
    for line in iter(pipe.readline, b""):
        text = line.decode("utf-8", errors="ignore")
        if "[download]" in text:
            text = text.replace("[download]", "[MINER] ⛏️ ")
        sys.stderr.write(text)
        sys.stderr.flush()

def create_package(packets: List[av.Packet], input_stream, max_dur: float, fmt: str):
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

def run_packager_thread(loop, conveyor_belt, req_data: StreamRequest, deno_path: str):
    # Setup Cookies
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as tf:
        tf.write(req_data.cookies)
        cookie_path = tf.name

    cmd = [
        sys.executable, "-m", "yt_dlp",
        "-f", "ba",
        "-S", "+abr,+tbr,+size",
        "--cookies", cookie_path,
        "--http-chunk-size", "10M",
        "--extractor-args", f"youtube:player_client=tv;playback_wait=2;po_token={req_data.po_token}",
        "-o", "-",
        str(req_data.url)
    ]

    if deno_path:
        cmd.extend(["--js-runtimes", f"deno:{deno_path}", "--remote-components", "ejs:npm"])

    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    threading.Thread(target=miner_log_monitor, args=(process.stderr,), daemon=True).start()

    try:
        in_container = av.open(process.stdout, mode="r")
        in_stream = in_container.streams.audio[0]
        codec = in_stream.codec_context.name
        out_fmt = CONFIG.CODEC_MAP.get(codec, "matroska")
        mime = f"audio/{out_fmt}"

        buffer: List[av.Packet] = []
        box_id = 0
        threshold = CONFIG.CHUNK_DURATION + CONFIG.BUFFER_TAIL

        for packet in in_container.demux(in_stream):
            if packet.dts is None: continue
            buffer.append(packet)
            curr_dur = float(packet.dts - buffer[0].dts) * in_stream.time_base

            if curr_dur >= threshold:
                mem_file, cutoff, size = create_package(buffer, in_stream, CONFIG.CHUNK_DURATION, out_fmt)
                asyncio.run_coroutine_threadsafe(conveyor_belt.put(Cargo(mem_file, box_id, mime, size)), loop)
                buffer = buffer[cutoff + 1:]
                box_id += 1

        if buffer:
            mem_file, _, size = create_package(buffer, in_stream, float("inf"), out_fmt)
            asyncio.run_coroutine_threadsafe(conveyor_belt.put(Cargo(mem_file, box_id, mime, size)), loop)

    except Exception as e:
        print(f"[PACKAGER ERROR] {e}")
    finally:
        process.kill()
        if os.path.exists(cookie_path): os.remove(cookie_path)
        asyncio.run_coroutine_threadsafe(conveyor_belt.put(None), loop)

# =============================================================================
# Logistics: Shipper (Async)
# =============================================================================

async def ship_cargo(session: aiohttp.ClientSession, cargo: Cargo, provider: str, api_key: str, results: list):
    cargo.buffer.seek(0)
    
    if provider == "assemblyai":
        url = "https://api.assemblyai.com/v2/upload"
        headers = {"Authorization": api_key, "Content-Type": "application/octet-stream"}
    else:
        url = "https://manage.deepgram.com/storage/assets"
        headers = {"Authorization": f"Token {api_key}", "Content-Type": cargo.mime_type}

    try:
        async with session.post(url, headers=headers, data=cargo.buffer) as resp:
            body = await resp.json()
            if resp.status < 400:
                ref = body.get("upload_url") if provider == "assemblyai" else (body.get("asset_id") or body.get("asset"))
                results.append({
                    "chunk_index": cargo.index,
                    "size_mb": cargo.size_mb,
                    "status": "success",
                    "reference": ref
                })
            else:
                results.append({"chunk_index": cargo.index, "status": "failed", "error": await resp.text()})
    except Exception as e:
        results.append({"chunk_index": cargo.index, "status": "error", "error": str(e)})
    finally:
        cargo.buffer.close()

async def run_shipper(conveyor_belt, provider, api_key):
    results = []
    async with aiohttp.ClientSession() as session:
        tasks = []
        while True:
            cargo = await conveyor_belt.get()
            if cargo is None: break
            tasks.append(asyncio.create_task(ship_cargo(session, cargo, provider, api_key, results)))
        if tasks:
            await asyncio.gather(*tasks)
    return results

# =============================================================================
# FastAPI Application
# =============================================================================

app = FastAPI(title="yt-dlp Logistics API")

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
        "versions": get_versions(),
        "storage": psutil.disk_usage('/')._asdict(),
        "memory": psutil.virtual_memory()._asdict()
    }

@app.post("/")
async def process_video(req: StreamRequest):
    # Resolve API Key
    api_key = req.api_key or os.environ.get("DEEPGRAM_API_KEY") or os.environ.get("ASSEMBLYAI_KEY")
    if not api_key:
        raise HTTPException(status_code=400, detail="No API Key provided (provider key missing)")

    deno_path = find_deno_runtime()
    conveyor_belt = asyncio.Queue()
    loop = asyncio.get_running_loop()

    start_time = time.time()
    
    # Start Shipper and Packager
    shipper_task = asyncio.create_task(run_shipper(conveyor_belt, req.provider, api_key))

    with ThreadPoolExecutor(max_workers=1) as pool:
        await loop.run_in_executor(pool, run_packager_thread, loop, conveyor_belt, req, deno_path)

    # Wait for shipping to finalize
    upload_results = await shipper_task
    
    duration = time.time() - start_time

    return {
        "success": True,
        "diagnostics": {
            "time_seconds": round(duration, 2),
            "deno_used": deno_path,
            "provider": req.provider
        },
        "assets": upload_results
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", 8000)))
