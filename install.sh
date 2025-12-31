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
# We clone with --depth 1 to minimize git history size (helps prevent git pack errors)
git clone --depth 1 "$PYAV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# 3. Configure Custom FFmpeg
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# 4. Install Build Dependencies
# Added 'wheel' to fix double-install issues
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
export CFLAGS="-I$VENDOR_DIR/include -Wno-deprecated-declarations"
export LDFLAGS="-L$VENDOR_DIR/lib"
# Rpath for Vercel/Lambda environment
export LDFLAGS="$LDFLAGS -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

# 8. Build and Install PyAV
echo "🛠️  Building PyAV..."
# Added --no-deps to prevent checking for numpy/pillow again
pip install . \
    --no-binary av \
    --no-build-isolation \
    --no-deps \
    -v

# --- THE FIX FOR ENOENT ERROR ---
# 9. Clean up source directory
# Once installed, we delete the source folder. 
# This stops Vercel from trying to scan the .git folder and crashing.
echo "🧹 Removing source code to prevent deployment errors..."
cd ..
rm -rf "$WORK_DIR"

echo "✅ Success. PyAV installed and workspace cleaned."
