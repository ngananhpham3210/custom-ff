#!/bin/bash

set -e

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

# --- THE FIX: Skip if already properly installed ---
if python -c "import av; print(av.__file__)" 2>/dev/null && [ -d "$RUNTIME_LIB_DIR" ] && [ "$(ls -A $RUNTIME_LIB_DIR 2>/dev/null)" ]; then
    echo "✅ PyAV with custom FFmpeg already installed. Skipping build."
    exit 0
fi

# --- Clean up previous build artifacts ---
echo "🧹 Cleaning up previous build artifacts..."
rm -rf "$WORK_DIR"
mkdir -p "$RUNTIME_LIB_DIR"

# --- Clone PyAV ---
echo "⬇️  Cloning PyAV repository..."
git clone --depth 1 "$PYAV_REPO" "$WORK_DIR"  # Added --depth 1 for faster clone
cd "$WORK_DIR"

# --- Configure Custom FFmpeg ---
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# --- Install Build Dependencies ---
pip install --upgrade pip setuptools cython pkgconfig

# --- Download Custom FFmpeg ---
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# --- Prepare Runtime Libraries ---
echo "🚚 Moving shared libraries to $RUNTIME_LIB_DIR..."
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# --- Configure Build Environment ---
VENDOR_DIR="$(pwd)/vendor"

echo "🔧 Patching pkg-config files..."
sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc

export PKG_CONFIG_PATH="$VENDOR_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
export CFLAGS="-I$VENDOR_DIR/include -Wno-deprecated-declarations"
export LDFLAGS="-L$VENDOR_DIR/lib -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

# --- Build and Install PyAV (ONLY ONCE) ---
echo "🛠️  Building PyAV from source..."
pip install . -v --no-build-isolation

# --- Cleanup build directory ---
cd ..
rm -rf "$WORK_DIR"

echo "✅ Success! PyAV installed with custom FFmpeg."
