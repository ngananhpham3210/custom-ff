#!/bin/bash
set -e

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

# 1. Clean previous builds
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
pip install --upgrade pip setuptools cython pkgconfig

# 5. Download Custom FFmpeg
# Downloads into PyAV-Custom/vendor
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# 6. Prepare Runtime Libraries
echo "🚚 Moving shared libraries to project root..."
# We use the actual path for the runtime copy
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# 7. --- FIX THE BUILD ERROR ---
VENDOR_DIR="$(pwd)/vendor"

# A. Patch the .pc files
# The .pc files likely have "prefix=/tmp/vendor" or similar hardcoded.
# We replace whatever the prefix line is with our actual current directory.
echo "🔧 Patching pkg-config files to point to $VENDOR_DIR..."
sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc

# B. Export Environment Variables
export PKG_CONFIG_PATH="$VENDOR_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"

# C. Force Compiler Flags (Safety Net)
# Even if pkg-config is still confused, this forces gcc to look in the right place
export CFLAGS="-I$VENDOR_DIR/include"
export LDFLAGS="-L$VENDOR_DIR/lib"

# 8. Build PyAV with rpath
# We bake /var/task/lib_native into the binary so it works on Vercel at runtime
export LDFLAGS="$LDFLAGS -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

echo "🛠️  Building PyAV..."
pip install . --no-binary av -v

echo "✅ Success. Libraries are in '$RUNTIME_LIB_DIR'"
