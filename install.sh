#!/bin/bash

set -e

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

# 1. Clean up previous build artifacts
echo "🧹 Cleaning up previous build artifacts..."
rm -rf "$WORK_DIR" "$RUNTIME_LIB_DIR"
mkdir -p "$RUNTIME_LIB_DIR"

# 2. Clone PyAV
echo "⬇️  Cloning PyAV repository..."
git clone --depth 1 "$PYAV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# 3. Configure Custom FFmpeg
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# 4. Install Build Dependencies
echo "📦 Installing build dependencies..."
pip install --upgrade pip setuptools cython pkgconfig wheel

# 5. Download Custom FFmpeg
echo "⬇️  Fetching custom FFmpeg vendor..."
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# 6. Prepare Runtime Libraries
echo "🚚 Moving shared libraries to $RUNTIME_LIB_DIR..."
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# 7. Configure Build Environment
VENDOR_DIR="$(pwd)/vendor"

echo "🔧 Patching pkg-config files..."
sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc

export PKG_CONFIG_PATH="$VENDOR_DIR"/lib/pkgconfig:$PKG_CONFIG_PATH

# --- THE FIX FOR RED LOGS ---
# -w suppresses ALL warnings so the log stays clean.
export CFLAGS="-I$VENDOR_DIR/include -w"
export LDFLAGS="-L$VENDOR_DIR/lib -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

# 8. Build and Install PyAV
echo "🛠️  Building PyAV (this may take a minute, please wait)..."
# Removed -v to stop the wall of text that Vercel marks as red.
pip install . \
    --no-binary av \
    --no-build-isolation \
    --no-deps

# 9. Clean up source directory (Prevents Vercel ENOENT errors)
echo "🧹 Removing source code to prevent deployment errors..."
cd ..
rm -rf "$WORK_DIR"

echo "✅ Success. PyAV installed and workspace cleaned."
