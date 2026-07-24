#!/bin/bash
set -e

# Config
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/build_output"
PODMAN_DIR="$PROJECT_ROOT/packaging/podman"

mkdir -p "$OUTPUT_DIR"
echo "Output directory: $OUTPUT_DIR"

echo "========================================="
echo "🛠️  Building/Updating Container Images"
echo "========================================="
podman build -t lcc-builder-ubuntu -f "$PODMAN_DIR/Containerfile.ubuntu" "$PODMAN_DIR"
podman build -t lcc-builder-almalinux -f "$PODMAN_DIR/Containerfile.almalinux" "$PODMAN_DIR"

echo "========================================="
echo "🚀 Starting Concurrent Compilations"
echo "========================================="

# Helper function to run podman build safely
# It copies the source to a temporary folder inside the container so multiple
# builds don't step on each other's toes (especially Flutter .dart_tool and Cargo target)
run_build() {
    local image=$1
    local script_commands=$2
    local label=$3
    
    echo "[$label] Starting build in $image..."
    podman run --rm -v "$PROJECT_ROOT:/src:ro" -v "$OUTPUT_DIR:/out:Z" "$image" bash -c "
        set -e
        echo '[$label] Copying source code to container workspace...'
        cp -a /src /workspace/src
        cd /workspace/src
        
        $script_commands
    "
    echo "[$label] ✅ Build finished!"
}

# 1. Ubuntu (DEB, AppImage, Tarball)
run_build "lcc-builder-ubuntu" "
  echo '[Ubuntu] Building DEB...'
  ./scripts/package_deb.sh && cp *.deb /out/ || echo '[Ubuntu] DEB build failed'
  
  echo '[Ubuntu] Building AppImage...'
  ./scripts/package_appimage.sh && cp *.AppImage /out/ || echo '[Ubuntu] AppImage build failed'
  
  echo '[Ubuntu] Building Tarball...'
  ./scripts/package_tarball.sh && cp *.tar.gz /out/ || echo '[Ubuntu] Tarball build failed'
" "Ubuntu" &
PID_UBUNTU=$!

# 2. AlmaLinux (RPM)
run_build "lcc-builder-almalinux" "
  echo '[AlmaLinux] Building RPM...'
  ./scripts/package_rpm.sh && cp *.rpm /out/ || echo '[AlmaLinux] RPM build failed'
" "AlmaLinux" &
PID_ALMA=$!

echo "⏳ Waiting for all builds to complete..."
wait $PID_UBUNTU
wait $PID_ALMA

echo "========================================="
echo "🎉 All builds completed successfully!"
echo "📦 Artifacts are located in: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
