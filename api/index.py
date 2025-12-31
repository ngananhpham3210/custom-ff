from fastapi import FastAPI
import os
import sys

app = FastAPI()

@app.get("/")
async def check_installation():
    response = {
        "status": "pending",
        "debug_info": {},
        "pyav_info": {},
        "error": None
    }

    # 1. CHECK FILESYSTEM
    # Vercel places your code in /var/task. We want to see if lib_native exists.
    expected_lib_path = "/var/task/lib_native"
    
    try:
        if os.path.exists(expected_lib_path):
            # List first 5 files to prove they are there
            files = os.listdir(expected_lib_path)
            response["debug_info"]["lib_native_exists"] = True
            response["debug_info"]["files_found"] = files[:5] 
            response["debug_info"]["total_files"] = len(files)
        else:
            response["debug_info"]["lib_native_exists"] = False
            response["debug_info"]["current_cwd"] = os.getcwd()
            response["debug_info"]["root_dir_listing"] = os.listdir(os.getcwd())
    except Exception as e:
        response["debug_info"]["fs_error"] = str(e)

    # 2. ATTEMPT IMPORT
    try:
        import av
        
        response["status"] = "success"
        response["pyav_info"] = {
            "version": av.__version__,
            "ffmpeg_dir": av.ffmpeg_dir, # Might be None for system installs
            "format_version": f"{av.format.libavformat_version_major}.{av.format.libavformat_version_minor}",
            "codec_version": f"{av.codec.libavcodec_version_major}.{av.codec.libavcodec_version_minor}",
        }
        
    except ImportError as e:
        response["status"] = "failed"
        response["error"] = str(e)
        # This is where we catch "libavformat.so cannot open shared object file"
        
    except Exception as e:
        response["status"] = "error"
        response["error"] = str(e)

    return response
