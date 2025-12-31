#!/bin/bash

set -e

# === Configuration ===
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

# === Check if already installed ===
if python -c "import av" 2>/dev/null && [ -d "$RUNTIME_LIB_DIR" ] && [ "$(ls -A $RUNTIME_LIB_DIR/*.so* 2>/dev/null)" ]; then
    echo "✅ PyAV already installed. Skipping."
    exit 0
fi

echo "🚀 Starting PyAV custom build..."

# === Clean previous builds ===
echo "🧹 Cleaning previous artifacts..."
rm -rf "$WORK_DIR" "$RUNTIME_LIB_DIR"
pip uninstall av -y 2>/dev/null || true

# === Create directories ===
mkdir -p "$RUNTIME_LIB_DIR"

# === Clone PyAV ===
echo "⬇️  Cloning PyAV..."
git clone --depth 1 "$PYAV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# === Setup custom FFmpeg config ===
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json

# === Install build dependencies ===
echo "📦 Installing build dependencies..."
pip install --upgrade pip setuptools cython pkgconfig --quiet

# === Download custom FFmpeg ===
echo "⬇️  Downloading custom FFmpeg..."
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# === Copy runtime libraries ===
echo "🚚 Copying shared libraries..."
cp vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# === Setup build environment ===
VENDOR_DIR="$(pwd)/vendor"

sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc

export PKG_CONFIG_PATH="$VENDOR_DIR/lib/pkgconfig"
export CFLAGS="-I$VENDOR_DIR/include -Wno-deprecated-declarations"
export LDFLAGS="-L$VENDOR_DIR/lib -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

# === Build and install PyAV ===
echo "🛠️  Building PyAV..."
pip install . --no-build-isolation --quiet

# === Cleanup ===
cd ..
rm -rf "$WORK_DIR"

# === Verify installation ===
echo "🔍 Verifying installation..."
python -c "import av; print(f'PyAV version: {av.__version__}')"

echo "✅ Done! PyAV installed successfully."
echo "📁 Runtime libraries: $RUNTIME_LIB_DIR/"
