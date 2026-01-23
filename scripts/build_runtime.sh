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
OUTPUT_DIR="runtime"
ARTIFACT_NAME="n8n-android-arm64.tar.gz"
METADATA_FILE="metadata.json"

# Dependency List (Package Names for lookup)
PACKAGES=("nodejs-lts" "libandroid-support" "libsqlite") 

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
    # Use awk to parse the stanza for the specific package
    local filename=$(awk -v pkg="$pkg_name" 'BEGIN{RS=""; FS="\n"} $0 ~ "Package: " pkg { for(i=1;i<=NF;i++) { if($i ~ /^Filename: /) { print substr($i, 11); exit } } }' Packages)
    
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

echo ">>> Generating Metadata manifest..."
# Calculate verify
# Generate timestamp version or use n8n version
VERSION_TAG="${N8N_VERSION}-android-build-$(date +%s)"

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
  "download_url": "https://github.com/\$GITHUB_REPOSITORY/releases/download/\$GITHUB_REF_NAME/$ARTIFACT_NAME",
  "built_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# Move artifacts to root of script output
mv "$ARTIFACT_NAME" ../
mv "$METADATA_FILE" ../

echo ">>> Done. Created $ARTIFACT_NAME and $METADATA_FILE"
