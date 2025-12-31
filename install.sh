#!/bin/bash

set -e

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

# --- THE FIX IS HERE ---
# 1. Force a clean state by deleting any cached artifacts from previous builds.
echo "🧹 Cleaning up previous build artifacts to ensure a fresh build..."
rm -rf "$WORK_DIR" "$RUNTIME_LIB_DIR"
mkdir -p "$RUNTIME_LIB_DIR"

# 2. Clone a fresh copy of PyAV every time. No more checking for existing dirs.
echo "⬇️  Cloning a fresh copy of PyAV repository..."
git clone "$PYAV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# 3. Configure Custom FFmpeg
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# 4. Install Build Dependencies
pip install --upgrade pip setuptools cython pkgconfig

# 5. Download Custom FFmpeg
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# 6. Prepare Runtime Libraries
echo "🚚 Moving shared libraries to project root ($RUNTIME_LIB_DIR)..."
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# 7. Configure Build Environment
VENDOR_DIR="$(pwd)/vendor"

# Patch pkg-config files to use correct build paths
echo "🔧 Patching pkg-config files to point to $VENDOR_DIR..."
sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc
export PKG_CONFIG_PATH="$VENDOR_DIR"/lib/pkgconfig:$PKG_CONFIG_PATH

# Force compiler flags and suppress deprecation warnings for a cleaner log
export CFLAGS="-I$VENDOR_DIR/include -Wno-deprecated-declarations"
export LDFLAGS="-L$VENDOR_DIR/lib"

# 8. Build PyAV with rpath for Vercel's runtime environment
export LDFLAGS="$LDFLAGS -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

echo "🛠️  Building PyAV from source..."

# The -v flag gives verbose output for easier debugging if it fails again
pip install . --no-binary av -v --no-build-isolation

echo "✅ Success. PyAV build complete and libraries are in '$RUNTIME_LIB_DIR'."
