#!/bin/bash
set -e

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native" # The folder name we will bundle

# 1. Clean previous build attempts for safety
rm -rf "$RUNTIME_LIB_DIR"
mkdir -p "$RUNTIME_LIB_DIR"

# 2. Clone PyAV
if [ ! -d "$WORK_DIR" ]; then
    git clone "$PYAV_REPO" "$WORK_DIR"
else
    cd "$WORK_DIR" && git pull && cd ..
fi

cd "$WORK_DIR"

# 3. Configure Custom FFmpeg
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# 4. Install Build Dependencies
pip install --upgrade pip setuptools cython

# 5. Download Custom FFmpeg
# This downloads into PyAV-Custom/vendor
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# 6. Prepare Runtime Libraries
# We copy the .so files from the build vendor folder to the project root
echo "🚚 Moving shared libraries to project root ($RUNTIME_LIB_DIR)..."
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# 7. Configure Build Environment
VENDOR_DIR="$(pwd)/vendor"
export PKG_CONFIG_PATH="$VENDOR_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"

# --- THE MAGIC SAUCE ---
# We tell the linker (ld) to bake the path '/var/task/lib_native' into the binary.
# /var/task is the standard root directory for Vercel Serverless Functions.
export LDFLAGS="-Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

echo "🛠️  Building PyAV with baked-in rpath..."
pip install . --no-binary av

echo "✅ Success. Libraries are in '$RUNTIME_LIB_DIR' and linked via rpath."
