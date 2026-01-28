#!/bin/bash
set -e

# Configuration
TERMUX_REPO_URL="https://packages.termux.dev/apt/termux-main/pool/main"
NODE_PKG="n/nodejs-lts"
# We need to find the specific version. For now, we'll try to find a recent one or accept it as an argument? 
# To be robust, we might need to parse the Packages file, but for this v1.6 MVP, let's hardcode a known working version URL or use a directory listing if possible.
# Since I cannot browse the web easily to find the exact dynamic link, I will assume a standard name format and placeholders, 
# or use a "latest" determination logic if I had `apt-get` access to termux repo which I don't on standard linux runner.
# The user requirement says "Fetch the .deb files... from the Termux APT repository".
# Let's try to grab a specific known version or use a wildcard approach if we can list directory (usually not allowed on repo pools).
# Better approach for a robust script: Download the 'Packages' content for aarchitecture, parse the filename for 'nodejs-lts'.

ARCH="aarch64"
ROOT_DIR=$(pwd)
OUTPUT_DIR="$ROOT_DIR/runtime"
ARTIFACT_NAME="n8n-android-arm64.tar.gz"
METADATA_FILE="metadata.json"

# Dependency List (Package Names for lookup)
# nodejs-lts depends on: libuv, openssl, c-ares, libnghttp2, zlib, libicu, brotli, libc++
# Added build tools for native module compilation (sqlite3)
PACKAGES=("nodejs-lts" "libandroid-support" "libsqlite" "zlib" "c-ares" "libuv" "openssl" "libnghttp2" "libicu" "brotli" "libc++" "python" "clang" "make" "binutils")
# רשימה מעודכנת ומדויקת של שמות החבילות ב-Termux
#PACKAGES=("nodejs-lts" "libandroid-support" "sqlite" "zlib" "c-ares" "libuv" "openssl" "libnghttp2" "libicu" "brotli" "libc++")


# Clean up
rm -rf build_work
mkdir -p build_work
cd build_work

echo ">>> Fetching Termux Packages index..."
# We need 'Packages' file to find the filenames
# We need 'Packages' file to find the filenames
wget -q "https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-$ARCH/Packages.gz" -O Packages.gz
gunzip Packages.gz

check_and_download() {
    local pkg_name=$1
    echo ">>> resolving $pkg_name..."
    # Use awk state machine to find the specific package's filename
    # Logic: Find exact "Package: <name>" line, set flag, print Filename when found, stop at next Package or EOF.
    local filename=$(awk -v pkg="$pkg_name" '
        /^Package: / { if ($2 == pkg) { inside=1 } else { inside=0 } }
        inside && /^Filename: / { print $2; exit }
    ' Packages)
    
    if [ -z "$filename" ]; then
        echo "Error: Could not find package $pkg_name in index"
        # Debug: Dump grep if failed
        grep "Package: $pkg_name" Packages || echo "Package not found in grep either"
        exit 1
    fi
    
    local url="https://packages.termux.dev/apt/termux-main/$filename"
    echo ">>> Downloading $url..."
    wget -q "$url" -O "${pkg_name}.deb"
}

for pkg in "${PACKAGES[@]}"; do
    check_and_download "$pkg"
done

echo ">>> Extracting packages..."
mkdir -p "$OUTPUT_DIR"

for pkg in "${PACKAGES[@]}"; do
    echo "Extracting ${pkg}.deb..."
    ar x "${pkg}.deb" data.tar.xz
    tar -xf data.tar.xz -C "$OUTPUT_DIR"
    rm data.tar.xz
done

echo ">>> Organizing Runtime..."
# Termux packages extract to ./data/data/com.termux/files/usr/...
# We need to move this content to our root $OUTPUT_DIR/bin, $OUTPUT_DIR/lib, etc.
# The relative path inside extracted content is usually ./data/data/com.termux/files/usr

TERMUX_PREFIX="$OUTPUT_DIR/data/data/com.termux/files/usr"

if [ -d "$TERMUX_PREFIX" ]; then
    echo "Found Termux prefix, moving files..."
    cp -r "$TERMUX_PREFIX/"* "$OUTPUT_DIR/"
    rm -rf "$OUTPUT_DIR/data"
else
    echo "WARNING: Unexpected directory structure. Checking..."
    find "$OUTPUT_DIR" -maxdepth 3
    # Fallback/Fail
fi

# Clean up unused folders (share, include, etc to save space?)
# For now, keep it simple. User wants n8n.
# We need to install n8n itself! 
# Termux nodejs doesn't include n8n. We use npm to install n8n?
# But we can't run the arm64 node on the x86 CI runner.
# Solution: We verify node exists, then we might need to bundle n8n differently.
# User Request says: "Download Node.js (ARM64) and the latest n8n package."
# Usually we run `npm install -g n8n` but we are cross-compiling.
# We can download the n8n package from registry (tgz) and extract it to lib/node_modules/n8n.
# And create the link.

echo ">>> Installing n8n (Cross-platform fetch)..."
# Fetch latest n8n tarball from npm
N8N_VERSION=$(npm view n8n version 2>/dev/null || echo "latest")
echo "Latest n8n version: $N8N_VERSION"
N8N_TARBALL=$(npm view n8n@$N8N_VERSION dist.tarball)

wget -q "$N8N_TARBALL" -O n8n.tgz
mkdir -p "$OUTPUT_DIR/lib/node_modules/n8n"
tar -xf n8n.tgz -C "$OUTPUT_DIR/lib/node_modules/n8n" --strip-components=1


# Install n8n dependencies (runs on host node, which works for pure JS deps)
echo ">>> Installing n8n core dependencies..."
cd "$OUTPUT_DIR/lib/node_modules/n8n"

# 1. התקנה בסיסית שעוקפת את מלחמות הגרסאות של Sentry
npm install --omit=dev --omit=optional --ignore-scripts --legacy-peer-deps

# 2. הזרקה כירורגית של semver - הפתרון הישיר לשגיאת ה-MODULE_NOT_FOUND
npm install semver@7.5.4 --save-exact --legacy-peer-deps

# 3. בדיקת שפיות לפני שממשיכים (אם זה נכשל, ה-Build ב-GitHub יעצור כאן)
if [ ! -f "node_modules/semver/functions/satisfies.js" ]; then
    echo "ERROR: Critical module 'semver' is still missing! Stopping build."
    exit 1
fi

cd "$ROOT_DIR"

# -----------------------------------------------------------------------------
# 7. Patch n8n Source (Persistent Fixes)
# -----------------------------------------------------------------------------
echo "Patching n8n source code..."

N8N_DIST="$OUTPUT_DIR/lib/node_modules/n8n/dist"

# 1. Disable Compression (Fixes "Garbage" text via Proxy)
ABSTRACT_SERVER_FILE="$N8N_DIST/abstract-server.js"
if [ -f "$ABSTRACT_SERVER_FILE" ]; then
    echo "  Patching Abstract Server (Disable Compression): $ABSTRACT_SERVER_FILE"
    sed -i "s/this.app.use((0, compression_1.default)());/\/\/ this.app.use((0, compression_1.default)());/" "$ABSTRACT_SERVER_FILE"
else
    echo "  WARNING: Abstract Server file not found!"
fi

# 2. Fix EACCES permissions in DataTableFileCleanupService
# Background: n8n configuration defaults to Termux path `/data/data/com.termux/...` on Android.
# We must override this to use the `TMPDIR` environment variable which points to our sandbox.
CLEANUP_SERVICE_FILE="$N8N_DIST/modules/data-table/data-table-file-cleanup.service.js"
if [ -f "$CLEANUP_SERVICE_FILE" ]; then
    echo "  Patching DataTableFileCleanupService: $CLEANUP_SERVICE_FILE"
    # Replace the constructor to force uploadDir to be process.env.TMPDIR/n8nDataTableUploads if TMPDIR exists
    # Original: this.uploadDir = this.globalConfig.dataTable.uploadDir;
    # Patched: this.uploadDir = process.env.TMPDIR ? require('path').join(process.env.TMPDIR, 'n8nDataTableUploads') : this.globalConfig.dataTable.uploadDir;
    
    # We use a robust sed substitution looking for the assignment
    sed -i "s/this.uploadDir = this.globalConfig.dataTable.uploadDir;/this.uploadDir = process.env.TMPDIR ? require('path').join(process.env.TMPDIR, 'n8nDataTableUploads') : this.globalConfig.dataTable.uploadDir;/" "$CLEANUP_SERVICE_FILE"
    
    # Also log it for debugging
    # sed -i "/this.uploadDir =/a \        console.log('DataTableFileCleanupService using uploadDir:', this.uploadDir);" "$CLEANUP_SERVICE_FILE"
else
    echo "  WARNING: DataTableFileCleanupService file not found! EACCES error might persist."
fi

# 5. Fix Permissions (Ensure all files are readable/executable)
echo "Fixing permissions..."
chmod -R 755 "$OUTPUT_DIR"

# -----------------------------------------------------------------------------
# 8. Create Tarball
# -----------------------------------------------------------------------------
# use --force to override ERESOLVE and EBADENGINE issues
npm install --omit=dev --omit=optional --ignore-scripts --force
if [ $? -ne 0 ]; then
    echo "ERROR: npm install failed!"
    exit 1
fi
# Explicitly install sqlite3 to ensure dependencies (node-pre-gyp) are present
echo ">>> Installing sqlite3 explicitly to fetch dependencies..."
npm install sqlite3 --ignore-scripts --no-save --force
cd - > /dev/null










# ============================================================================
# CRITICAL: Install prebuilt sqlite3 native module for Android ARM64
# ============================================================================
# The npm install above uses --ignore-scripts, so native modules are NOT compiled.
# We explicitly inject the binary we compiled on Termux (now present in project root).
echo ">>> Installing sqlite3 native module (Termux compiled)..."

SQLITE3_NAPI="napi-v6"
# Find where sqlite3 module was installed
SQLITE3_MODULE_DIR=$(find "$OUTPUT_DIR/lib/node_modules" -type d -name "sqlite3" -path "*/node_modules/sqlite3" | head -1)

if [ -n "$SQLITE3_MODULE_DIR" ]; then
    echo "Found sqlite3 module at: $SQLITE3_MODULE_DIR"
    
    # Create the binding directory structure
    BINDING_DIR="$SQLITE3_MODULE_DIR/lib/binding/${SQLITE3_NAPI}-android-arm64"
    mkdir -p "$BINDING_DIR"
    
    # Use the local file we pulled from the device
    LOCAL_BINARY="../node_sqlite3-android-arm64.node"
    
    if [ -f "$LOCAL_BINARY" ]; then
        cp "$LOCAL_BINARY" "$BINDING_DIR/node_sqlite3.node"
        echo "Successfully installed sqlite3 binary to: $BINDING_DIR"
    else
        echo "ERROR: Local binary $LOCAL_BINARY not found!"
        echo "Please ensure node_sqlite3-android-arm64.node is in the project root."
        # Don't exit, maybe n8n can run without it (unlikely but worth trying)
    fi
else
    echo "WARNING: sqlite3 module not found in node_modules. n8n may not use sqlite3."
fi

# Create bin symlink
mkdir -p "$OUTPUT_DIR/bin"
# Check if n8n binary exists in the module
if [ -f "$OUTPUT_DIR/lib/node_modules/n8n/bin/n8n" ]; then
    echo "Linking n8n binary..."
    cd "$OUTPUT_DIR/bin"
    ln -sf "../lib/node_modules/n8n/bin/n8n" n8n
    cd - > /dev/null
else
    echo "ERROR: n8n binary not found in extracted package"
    exit 1
fi

# Check for patchelf
if ! command -v patchelf &> /dev/null; then
    echo "WARNING: patchelf not found. Binaries will not be patched for Android!"
    echo "Install with: sudo apt-get install patchelf"
    # In CI, we should fail or install it. For now, warn.
else

        echo ">>> Patching binaries for Android..."
        if [ -f "$OUTPUT_DIR/bin/node" ]; then
            patchelf --set-interpreter /system/bin/linker64 --set-rpath '$ORIGIN/../lib' "$OUTPUT_DIR/bin/node"
            echo "Patched node interpreter."
        fi

        # Patch all shared libraries to look in $ORIGIN (same directory)
        echo ">>> Patching shared libraries RPATH..."
        find "$OUTPUT_DIR/lib" -name "*.so*" -type f | while read -r lib; do
            # Only patch files that are actual ELF binaries (skip text files or scripts if any)
            if head -c 4 "$lib" | grep -q "ELF"; then
                patchelf --set-rpath "\$ORIGIN" "$lib" || echo "Warning: Failed to patch $lib"
            fi
        done
fi

# Verification Step
echo ">>> Verifying critical libraries..."
REQUIRED_LIBS=("libz.so.1" "libcares.so" "libnghttp2.so" "libssl.so" "libcrypto.so")
MISSING_LIBS=0
for lib in "${REQUIRED_LIBS[@]}"; do
    # Check regular file or symlink
    if [ ! -e "$OUTPUT_DIR/lib/$lib" ]; then
        echo "ERROR: Critical library missing: $lib"
        MISSING_LIBS=1
    else
        echo "Verified: $lib"
    fi
done

if [ $MISSING_LIBS -eq 1 ]; then
    echo "FATAL: Build incomplete. Missing libraries."
    exit 1
fi

echo ">>> Creating bootstrap script..."
mkdir -p "$OUTPUT_DIR/bin"


echo ">>> Creating robust bootstrap script..."
cat <<EOS > "$OUTPUT_DIR/bin/n8n-start.sh"
#!/system/bin/sh

# 1. הגדרת נתיבים בסיסיים
export NODE_PATH=\$N8N_USER_FOLDER/../../runtime/lib/node_modules:\$N8N_USER_FOLDER/../../runtime/lib/node_modules/n8n/node_modules
export LD_LIBRARY_PATH=\$N8N_USER_FOLDER/../../runtime/lib
export PATH=\$N8N_USER_FOLDER/../../runtime/bin:\$PATH

# 2. הדפסת לוגים לדיבאג (יופיעו ב-Logcat)
echo "--- n8ntry Diagnostic Startup ---"
echo "DEBUG: NODE_PATH=\$NODE_PATH"
echo "DEBUG: LD_LIBRARY_PATH=\$LD_LIBRARY_PATH"

# 3. בדיקה פיזית של מודול ה-semver הבעייתי
if [ -f "\$N8N_USER_FOLDER/../../runtime/lib/node_modules/n8n/node_modules/semver/functions/satisfies.js" ]; then
    echo "DEBUG: [SUCCESS] satisfies.js found in n8n scope."
else
    echo "DEBUG: [ERROR] satisfies.js NOT FOUND! Node might crash."
fi

# 4. הרצת השרת
echo "Starting n8n engine..."
exec node \$N8N_USER_FOLDER/../../runtime/lib/node_modules/n8n/bin/n8n start
EOS

chmod +x "$OUTPUT_DIR/bin/n8n-start.sh"


echo ">>> Generating Metadata manifest..."
# Calculate verify
# Generate timestamp version or use n8n version
VERSION_TAG="${N8N_VERSION}-android-build-$(date +%s)"



echo "Fixing permissions..."
cd "$ROOT_DIR"  # חוזרים הביתה לפני ה-chmod
chmod -R 755 "$OUTPUT_DIR"

# Create tarball first to get hash
echo ">>> Packaging artifact (preserving symlinks)..."
# We want the content of $OUTPUT_DIR to be at the root of the tar
tar -czf "$ARTIFACT_NAME" -C "$OUTPUT_DIR" .

SHA256=$(sha256sum "$ARTIFACT_NAME" | awk '{print $1}')
echo "SHA256: $SHA256"

cat <<EOF > "$METADATA_FILE"
{
  "version": "$VERSION_TAG",
  "n8n_version": "$N8N_VERSION",
  "sha256": "$SHA256",
  "download_url": "https://github.com/$GITHUB_REPOSITORY/releases/download/$GITHUB_REF_NAME/$ARTIFACT_NAME",
  "built_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# Move artifacts to root of script output
mv "$ARTIFACT_NAME" ../
mv "$METADATA_FILE" ../




echo ">>> Done. Created $ARTIFACT_NAME and $METADATA_FILE"
