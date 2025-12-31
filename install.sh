#!/bin/bash
set -e

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

# 1. Clean previous builds
rm -rf "$RUNTIME_LIB_DIR" "$WORK_DIR"
mkdir -p "$RUNTIME_LIB_DIR"

# 2. Clone PyAV
git clone "$PYAV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# 3. Configure Custom FFmpeg
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# 4. Install Build Dependencies
pip install --upgrade pip setuptools cython pkgconfig

# 5. Download Custom FFmpeg
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# 6. Prepare Runtime Libraries
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# 7. Configure Build Environment
VENDOR_DIR="$(pwd)/vendor"

# Patch pkg-config files
sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc
export PKG_CONFIG_PATH="$VENDOR_DIR"/lib/pkgconfig:$PKG_CONFIG_PATH

# --- THE CHANGE IS HERE ---
# Force compiler flags and suppress deprecation warnings for a cleaner log
export CFLAGS="-I$VENDOR_DIR/include -Wno-deprecated-declarations"
export LDFLAGS="-L$VENDOR_DIR/lib"

# 8. Build PyAV with rpath
export LDFLAGS="$LDFLAGS -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

echo "🛠️  Building PyAV (suppressing deprecation warnings)..."
pip install . --no-binary av

echo "✅ Success. Libraries are in '$RUNTIME_LIB_DIR'"
