#!/bin/bash

set -e

# --- SENTINEL CHECK ---
# If this file exists, it means the script already ran in this build session.
if [ -f ".pyav_installed" ]; then
    echo "⏭️  PyAV and Deno already built/installed in this session. Skipping."
    exit 0
fi

echo "====================================="
echo "🚀 Installing Deno"
echo "====================================="

# We set DENO_INSTALL to the current directory
export DENO_INSTALL="$PWD"
curl -fsSL https://deno.land/install.sh | sh

DENO_BIN="./bin/deno"

if [[ ! -f "$DENO_BIN" ]]; then
    echo "❌ Error: Deno binary not found at $DENO_BIN"
    exit 1
fi

chmod +x "$DENO_BIN"
"$DENO_BIN" --version

# Add Deno to PATH for the rest of this script session
export PATH="$PWD/bin:$PATH"

echo "====================================="
echo "✅ Deno installation complete"
echo "====================================="

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

echo "🗑️  FORCING CLEAN STATE..."
pip uninstall -y av || true
rm -rf "$WORK_DIR" "$RUNTIME_LIB_DIR"
mkdir -p "$RUNTIME_LIB_DIR"

# 1. Clone fresh
echo "⬇️  Cloning fresh PyAV..."
git clone --depth 1 "$PYAV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# 2. Configure Custom FFmpeg
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# 3. Install Build Tools
echo "📦 Installing build tools..."
pip install --no-cache-dir cython pkgconfig wheel setuptools

# 4. Download Custom FFmpeg
echo "⬇️  Fetching custom FFmpeg vendor..."
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# 5. Prepare Runtime Libraries
echo "🚚 Moving shared libraries to $RUNTIME_LIB_DIR..."
# Note: $RUNTIME_LIB_DIR is one level up from $WORK_DIR
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# 6. Configure Build Environment
VENDOR_DIR="$(pwd)/vendor"
sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc
export PKG_CONFIG_PATH="$VENDOR_DIR"/lib/pkgconfig:$PKG_CONFIG_PATH
export CFLAGS="-I$VENDOR_DIR/include -w"
export LDFLAGS="-L$VENDOR_DIR/lib -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

# 7. Build and Install PyAV
echo "🛠️  Building PyAV from source..."
pip install . --no-cache-dir --no-binary av --no-build-isolation --no-deps

# 8. Clean up source
echo "🧹 Removing source code..."
cd ..
rm -rf "$WORK_DIR"

# --- CREATE SENTINEL ---
# This prevents the script from running a second time
touch ".pyav_installed"

echo "✅ Success. Deno installed and PyAV build complete."
