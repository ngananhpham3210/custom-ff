#!/bin/bash

set -e

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

echo "🗑️  FORCING CLEAN STATE: Removing all caches and existing installs..."

# 1. Force uninstall any existing PyAV to prevent the "uninstalling" log later
pip uninstall -y av || true

# 2. Delete build directories completely
rm -rf "$WORK_DIR" "$RUNTIME_LIB_DIR"
mkdir -p "$RUNTIME_LIB_DIR"

# 3. Clone fresh (no history)
echo "⬇️  Cloning fresh PyAV..."
git clone --depth 1 "$PYAV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# 4. Configure Custom FFmpeg
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# 5. Install Build Tools (No Cache)
echo "📦 Installing build tools (no-cache)..."
pip install --no-cache-dir --upgrade pip setuptools cython pkgconfig wheel

# 6. Download Custom FFmpeg
echo "⬇️  Fetching custom FFmpeg vendor..."
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# 7. Prepare Runtime Libraries
echo "🚚 Moving shared libraries to $RUNTIME_LIB_DIR..."
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# 8. Configure Build Environment
VENDOR_DIR="$(pwd)/vendor"
sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc

export PKG_CONFIG_PATH="$VENDOR_DIR"/lib/pkgconfig:$PKG_CONFIG_PATH
# -w silences the red warnings
export CFLAGS="-I$VENDOR_DIR/include -w"
export LDFLAGS="-L$VENDOR_DIR/lib -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

# 9. Build and Install PyAV (FORCE REBUILD)
echo "🛠️  Building PyAV from source..."
# --no-cache-dir: ignores pip's internal download/wheel cache
# --force-reinstall: ensures it doesn't try to be "smart" about existing files
# --no-binary av: ensures it compiles C code and doesn't download a pre-built wheel
pip install . \
    --no-cache-dir \
    --force-reinstall \
    --no-binary av \
    --no-build-isolation \
    --no-deps

# 10. Clean up source
echo "🧹 Removing source code..."
cd ..
rm -rf "$WORK_DIR"

echo "✅ Success. Fresh PyAV build complete."
