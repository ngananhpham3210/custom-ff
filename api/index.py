import os
import sys
import subprocess
import time
import io
import asyncio
import tempfile
import threading
from typing import List, NamedTuple, Optional
from dataclasses import dataclass

# --- VERCEL ENVIRONMENT SETUP ---
# 1. Tell Python where to find your custom built FFmpeg libraries (.so files)
HOME = os.getcwd()
LIB_PATH = os.path.join(HOME, "lib_native")
BIN_PATH = os.path.join(HOME, "bin")

os.environ["LD_LIBRARY_PATH"] = f"{LIB_PATH}:{os.environ.get('LD_LIBRARY_PATH', '')}"
os.environ["PATH"] = f"{BIN_PATH}:{os.environ.get('PATH', '')}"

# Verify we can import PyAV (if this fails, the build failed)
try:
    import av
    import aiohttp
    import psutil
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.middleware.cors import CORSMiddleware
    from fastapi.responses import JSONResponse
    from pydantic import BaseModel, HttpUrl
    PYAV_AVAILABLE = True
except ImportError as e:
    PYAV_AVAILABLE = False
    IMPORT_ERROR = str(e)

# --- CONFIGURATION ---
CODEC_MAP = {"opus": "webm", "aac": "mp4", "mp3": "mp3", "vorbis": "ogg"}

class StreamRequest(BaseModel):
    url: HttpUrl
    cookies: str
    po_token: str
    provider: str = "deepgram" 
    chunk_duration: int = 1800   
    buffer_tail: int = 600      

class Cargo(NamedTuple):
    buffer: io.BytesIO
    index: int
    mime_type: str
    size_mb: float

app = FastAPI()

# Standard CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- DIAGNOSTIC HELPERS ---
def get_binary_status():
    results = {}
    for name in ["ffmpeg", "ffprobe", "deno", "yt-dlp"]:
        try:
            path = subprocess.check_output(["which", name], text=True).strip()
            results[name] = f"OK: {path}"
        except:
            results[name] = "MISSING"
    return results

# --- CORE LOGIC (REUSED FROM PREVIOUS) ---

def create_package(packets: List['av.Packet'], input_stream, max_dur: float, fmt: str):
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
    return output_mem, cutoff_idx, round(output_mem.getbuffer().nbytes / 1024 / 1024, 2)

async def ship_cargo(session, cargo, provider, results):
    # (Same as previous shipper logic)
    headers = {"Authorization": os.getenv("DEEPGRAM_KEY", "d6bf3bf38250b6370e424a0805f6ef915ae00bec")}
    if provider == "assemblyai":
        url = "https://api.assemblyai.com/v2/upload"
        headers = {"Authorization": os.getenv("ASSEMBLYAI_KEY", "193053bc6ff84ba9aac2465506f47d48")}
    else:
        url = "https://manage.deepgram.com/storage/assets"
    
    try:
        async with session.post(url, headers=headers, data=cargo.buffer) as resp:
            body = await resp.json()
            results.append({"index": cargo.index, "status": resp.status, "body": body})
    finally:
        cargo.buffer.close()

def run_packager(loop, conveyor_belt, req, cookie_path):
    # Use full path for Deno if found in bin
    deno_bin = os.path.join(BIN_PATH, "deno")
    
    cmd = [
        sys.executable, "-m", "yt_dlp",
        "-f", "ba",
        "--cookies", cookie_path,
        "--extractor-args", f"youtube:player_client=tv;po_token={req.po_token}",
        "-o", "-", str(req.url)
    ]
    
    if os.path.exists(deno_bin):
        cmd.extend(["--js-runtimes", f"deno:{deno_bin}"])

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        container = av.open(proc.stdout, mode="r")
        stream = container.streams.audio[0]
        out_fmt = CODEC_MAP.get(stream.codec_context.name, "matroska")
        
        buffer = []
        box_id = 0
        for packet in container.demux(stream):
            if packet.dts is None: continue
            buffer.append(packet)
            if float(packet.dts - buffer[0].dts) * stream.time_base >= (req.chunk_duration + req.buffer_tail):
                mem, cutoff, size = create_package(buffer, stream, req.chunk_duration, out_fmt)
                asyncio.run_coroutine_threadsafe(conveyor_belt.put(Cargo(mem, box_id, f"audio/{out_fmt}", size)), loop)
                buffer = buffer[cutoff+1:]
                box_id += 1
        if buffer:
            mem, _, size = create_package(buffer, stream, 999999, out_fmt)
            asyncio.run_coroutine_threadsafe(conveyor_belt.put(Cargo(mem, box_id, f"audio/{out_fmt}", size)), loop)
    finally:
        proc.kill()
        asyncio.run_coroutine_threadsafe(conveyor_belt.put(None), loop)

# --- ROUTES ---

@app.get("/")
async def health_check():
    return {
        "pyav_ready": PYAV_AVAILABLE,
        "import_error": IMPORT_ERROR if not PYAV_AVAILABLE else None,
        "binaries": get_binary_status(),
        "ld_path": os.environ.get("LD_LIBRARY_PATH"),
        "cwd": os.getcwd()
    }

@app.post("/")
async def handle_request(req: StreamRequest):
    if not PYAV_AVAILABLE:
        raise HTTPException(500, f"PyAV not installed: {IMPORT_ERROR}")
    
    loop = asyncio.get_running_loop()
    conveyor_belt = asyncio.Queue()
    results = []
    
    # ALWAYS use /tmp on Vercel
    with tempfile.NamedTemporaryFile(mode="w", dir="/tmp", suffix=".txt", delete=False) as tf:
        tf.write(req.cookies)
        cookie_path = tf.name

    try:
        async with aiohttp.ClientSession() as session:
            # Start packager thread
            threading.Thread(target=run_packager, args=(loop, conveyor_belt, req, cookie_path), daemon=True).start()
            
            # Consume queue
            while True:
                cargo = await conveyor_belt.get()
                if cargo is None: break
                await ship_cargo(session, cargo, req.provider, results)
        
        return {"success": True, "chunks": results}
    finally:
        if os.path.exists(cookie_path):
            os.remove(cookie_path)
