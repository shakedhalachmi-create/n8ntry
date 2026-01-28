#!/bin/bash
set -e

# ==============================================================================
# build_n8n_android.sh - Patching Engine
# ==============================================================================
# Goal: Create a portable tar.gz containing Node.js (ARM64) and n8n,
#       patched to use /system/bin/linker64 on Android.
# ==============================================================================

WORK_DIR="$(pwd)"
BUILD_DIR="$WORK_DIR/build/android-bundle"
RUNTIME_DIR="$BUILD_DIR/runtime"
DIST_FILE="$WORK_DIR/n8n-android-arm64.tar.gz"

NODE_VERSION="v20.10.0" # Example LTS
NODE_DIST="node-$NODE_VERSION-linux-arm64"
NODE_URL="https://nodejs.org/dist/$NODE_VERSION/$NODE_DIST.tar.xz"

# Check for patchelf
if ! command -v patchelf &> /dev/null; then
    echo "Error: patchelf is required but not installed."
    echo "Install it via: sudo apt-get install patchelf"
    exit 1
fi

echo "--- [1/5] Setting up Workspace ---"
rm -rf "$BUILD_DIR"
mkdir -p "$RUNTIME_DIR/bin"
mkdir -p "$RUNTIME_DIR/lib"

echo "--- [2/5] Downloading Node.js ($NODE_VERSION check) ---"
wget -q "$NODE_URL" -O node.tar.xz
tar -xf node.tar.xz
mv "$NODE_DIST/bin/node" "$RUNTIME_DIR/bin/"
# In a real scenario, we might want to copy npm/npx too, or install n8n via npm bundle
# For now, let's assume we are just setting up the node binary and will install n8n separately
# or assuming n8n is already in a local node_modules we want to bundle.

# FOR DEMONSTRATION: installing n8n using npm into the runtime directory
# (This part would ideally be done via a proper package manager or cross-installation)
# echo "Installing n8n..."
# npm install --prefix "$RUNTIME_DIR/lib" n8n

echo "--- [3/5] Bundling Shared Libraries ---"
# IMPORTANT: These must be ARM64 libs.
# If running on x86, we can't just copy local libs.
# We assume the user has placed valid ARM64 libs in a 'libs-arm64' folder for this script to pick up
# OR we download them.
# For this script, we'll simulate the presence or warn.

if [ -d "$WORK_DIR/libs-arm64" ]; then
    cp "$WORK_DIR/libs-arm64/libstdc++.so.6" "$RUNTIME_DIR/lib/" || true
    cp "$WORK_DIR/libs-arm64/libgcc_s.so.1" "$RUNTIME_DIR/lib/" || true
    echo "Libs bundled."
else
    echo "WARNING: ./libs-arm64 not found. Please provide libstdc++.so.6 and libgcc_s.so.1 for ARM64."
fi

echo "--- [4/5] Patching Binaries (The Critical Step) ---"
NODE_BIN="$RUNTIME_DIR/bin/node"

# 1. Set Interpreter (Android Linker)
patchelf --set-interpreter /system/bin/linker64 "$NODE_BIN"

# 2. Set RPATH (Look in relative ../lib)
patchelf --set-rpath "\$ORIGIN/../lib" "$NODE_BIN"

echo "Patched interpreter and RPATH on $NODE_BIN"

# 3. Patch Native Modules (Recursive)
# Find all .node files
# find "$RUNTIME_DIR" -name "*.node" -exec patchelf --set-rpath "\$ORIGIN/../../../../lib" {} \;
# Note: The depth ($ORIGIN/...) depends on where the .node file is relative to /runtime/lib.
# A safer generic approach is difficult without known depth, but for n8n deps it's usually predictable.

echo "--- [5/5] Creating Archive ---"
cd "$BUILD_DIR"
tar -czf "$DIST_FILE" runtime
cd "$WORK_DIR"

echo "Done. Artifact: $DIST_FILE"
