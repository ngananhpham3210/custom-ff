#!/bin/bash

set -e

# =============================================================================
# PyAV Custom FFmpeg Installation Script
# =============================================================================

# --- Configuration ---
PYAV_REPO="https://github.com/PyAV-Org/PyAV.git"
FFMPEG_URL="https://github.com/ngananhpham3210/pyav-ffmpeg/releases/download/custom-audio/ffmpeg-{platform}.tar.gz"
WORK_DIR="PyAV-Custom"
RUNTIME_LIB_DIR="lib_native"

# --- Functions ---
cleanup() {
    echo "🧹 Cleaning up build directory..."
    rm -rf "$WORK_DIR"
}

check_installed() {
    if python -c "import av" 2>/dev/null && [ -d "$RUNTIME_LIB_DIR" ] && [ "$(ls -A $RUNTIME_LIB_DIR/*.so* 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

# --- Main Script ---
echo "=============================================="
echo "   PyAV + Custom FFmpeg Installer"
echo "=============================================="

# Step 1: Check if already installed
if check_installed; then
    echo "✅ PyAV already installed with custom FFmpeg. Skipping."
    exit 0
fi

# Step 2: Clean previous builds
echo ""
echo "[1/7] Cleaning previous builds..."
rm -rf "$WORK_DIR" "$RUNTIME_LIB_DIR"
mkdir -p "$RUNTIME_LIB_DIR"

# Step 3: Clone PyAV
echo ""
echo "[2/7] Cloning PyAV repository..."
git clone --depth 1 "$PYAV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# Step 4: Install build dependencies
echo ""
echo "[3/7] Installing build dependencies..."
pip install --upgrade pip setuptools cython pkgconfig --quiet

# Step 5: Download custom FFmpeg
echo ""
echo "[4/7] Downloading custom FFmpeg..."
echo "{\"url\": \"$FFMPEG_URL\"}" > scripts/ffmpeg-custom.json
python scripts/fetch-vendor.py --config-file scripts/ffmpeg-custom.json vendor

# Step 6: Copy runtime libraries
echo ""
echo "[5/7] Copying runtime libraries..."
cp -r vendor/lib/*.so* "../$RUNTIME_LIB_DIR/"

# Step 7: Setup build environment
echo ""
echo "[6/7] Configuring build environment..."
VENDOR_DIR="$(pwd)/vendor"

sed -i "s|^prefix=.*|prefix=$VENDOR_DIR|g" "$VENDOR_DIR"/lib/pkgconfig/*.pc

export PKG_CONFIG_PATH="$VENDOR_DIR/lib/pkgconfig"
export CFLAGS="-I$VENDOR_DIR/include -Wno-deprecated-declarations"
export LDFLAGS="-L$VENDOR_DIR/lib -Wl,-rpath,/var/task/$RUNTIME_LIB_DIR"

# Step 8: Build and install PyAV
echo ""
echo "[7/7] Building and installing PyAV..."
pip install . --no-build-isolation --quiet

# Step 9: Cleanup
cd ..
cleanup

# Step 10: Verify installation
echo ""
echo "=============================================="
if python -c "import av; print(f'PyAV version: {av.__version__}')" 2>/dev/null; then
    echo "✅ Installation successful!"
    echo "   Libraries location: $RUNTIME_LIB_DIR/"
    ls -la "$RUNTIME_LIB_DIR/" | head -10
else
    echo "❌ Installation failed!"
    exit 1
fi
echo "=============================================="
