#!/bin/bash
#
# build_macos.sh — Compila linux_cloud_connector para macOS
#
# Produce un Universal Binary que corre nativamente en:
#   • Apple Silicon (arm64)  — MacBooks M1/M2/M3/M4
#   • Intel (x86_64)         — MacBooks anteriores a 2021
#
# Uso:
#   ./build_macos.sh              # build release universal (por defecto)
#   ./build_macos.sh --debug      # build debug (más rápido, sin optimizaciones)
#   ./build_macos.sh --no-bridge  # omitir regeneración del bridge Rust-Flutter
#

set -euo pipefail

cd "$(dirname "$0")/.."

# ── Opciones ──────────────────────────────────────────────────────────────────
BUILD_MODE="release"
REGEN_BRIDGE=true

for arg in "$@"; do
    case "$arg" in
        --debug)      BUILD_MODE="debug" ;;
        --no-bridge)  REGEN_BRIDGE=false ;;
        --help|-h)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//'
            exit 0
            ;;
        *) echo "Opción desconocida: $arg (usa --help)" >&2; exit 1 ;;
    esac
done

# ── Colores ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
die()     { echo -e "${RED}✗ ERROR:${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}$*${NC}"; }

# ── Prerequisitos ─────────────────────────────────────────────────────────────
header "Verificando prerequisitos"

command -v flutter &>/dev/null || die "Flutter no está instalado. Consulta https://docs.flutter.dev/get-started/install/macos"
command -v cargo   &>/dev/null || die "Rust/Cargo no está instalado. Ejecuta: curl https://sh.rustup.rs -sSf | sh"
command -v pod     &>/dev/null || die "CocoaPods no está instalado. Ejecuta: sudo gem install cocoapods"
command -v lipo    &>/dev/null || die "lipo no encontrado. Instala Xcode Command Line Tools: xcode-select --install"

FLUTTER_VER=$(flutter --version --machine 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('frameworkVersion','?'))" 2>/dev/null || flutter --version 2>/dev/null | head -1)
RUST_VER=$(rustc --version 2>/dev/null | awk '{print $2}')

success "Flutter $FLUTTER_VER"
success "Rust $RUST_VER"

# ── Targets de Rust ───────────────────────────────────────────────────────────
header "Configurando targets de Rust"

# Ambos targets son necesarios: flutter build macos produce universal binary
# compilando el código nativo para arm64 y x86_64 simultáneamente.
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    if rustup target list --installed 2>/dev/null | grep -q "^$target$"; then
        success "$target (ya instalado)"
    else
        info "Instalando $target..."
        rustup target add "$target"
        success "$target instalado."
    fi
done

# ── Soporte macOS ─────────────────────────────────────────────────────────────
if [ ! -d "macos" ]; then
    header "Habilitando soporte macOS"
    info "Creando directorio macos/..."
    flutter create --platforms=macos .
    success "Soporte macOS habilitado."
fi

# ── Bridge Rust-Flutter ───────────────────────────────────────────────────────
if [ "$REGEN_BRIDGE" = true ]; then
    header "Generando bridge Rust-Flutter"
    if command -v flutter_rust_bridge_codegen &>/dev/null; then
        flutter_rust_bridge_codegen generate
        success "Bridge generado."
    else
        warn "flutter_rust_bridge_codegen no encontrado — omitiendo regeneración."
        warn "Si hiciste cambios en la API Rust, ejecuta ./scripts/setup_macos.sh primero."
    fi
fi

# ── Dependencias ──────────────────────────────────────────────────────────────
header "Instalando dependencias"

info "Flutter pub get..."
flutter pub get
success "Dependencias Dart instaladas."

info "CocoaPods..."
(cd macos && pod install --silent)
success "CocoaPods instalados."

# ── Build ─────────────────────────────────────────────────────────────────────
header "Compilando aplicación (modo: $BUILD_MODE)"
info "Flutter compila un Universal Binary (arm64 + x86_64) en un solo paso."

BUILD_START=$(date +%s)

if [ "$BUILD_MODE" = "release" ]; then
    flutter build macos --release
else
    flutter build macos --debug
fi

BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))

# ── Verificación de arquitecturas ─────────────────────────────────────────────
header "Verificando Universal Binary"

APP_PATH="build/macos/Build/Products/Release/linux_cloud_connector.app"
[ "$BUILD_MODE" = "debug" ] && APP_PATH="build/macos/Build/Products/Debug/linux_cloud_connector.app"

MAIN_BIN="$APP_PATH/Contents/MacOS/linux_cloud_connector"

if [ ! -f "$MAIN_BIN" ]; then
    die "Binario no encontrado en $MAIN_BIN"
fi

ARCH_INFO=$(lipo -info "$MAIN_BIN")
if echo "$ARCH_INFO" | grep -q "arm64" && echo "$ARCH_INFO" | grep -q "x86_64"; then
    success "Universal Binary confirmado: arm64 + x86_64"
else
    warn "El binario no es universal: $ARCH_INFO"
fi

# Verificar todos los frameworks
BINARIES_OK=0
BINARIES_FAIL=0
while IFS= read -r -d '' binary; do
    info_out=$(lipo -info "$binary" 2>/dev/null || true)
    if echo "$info_out" | grep -q "arm64" && echo "$info_out" | grep -q "x86_64"; then
        BINARIES_OK=$((BINARIES_OK + 1))
    elif [ -n "$info_out" ]; then
        warn "Solo una arquitectura: $(basename "$binary")"
        BINARIES_FAIL=$((BINARIES_FAIL + 1))
    fi
done < <(find "$APP_PATH" -type f -name "*.framework" -prune -o -type f ! -name "*.plist" ! -name "*.json" ! -name "*.bin" ! -name "*.otf" ! -name "*.ttf" ! -name "*.frag" ! -name "*.dat" ! -name "*.Z" ! -name "*.icns" ! -name "*.car" ! -name "*.nib" ! -name "*.xcprivacy" ! -name "CodeResources" -print0 2>/dev/null)

# También verificar binarios dentro de .framework
while IFS= read -r -d '' framework; do
    bin_name=$(basename "$framework" .framework)
    bin_path="$framework/Versions/A/$bin_name"
    [ -f "$bin_path" ] || continue
    info_out=$(lipo -info "$bin_path" 2>/dev/null || true)
    if echo "$info_out" | grep -q "arm64" && echo "$info_out" | grep -q "x86_64"; then
        BINARIES_OK=$((BINARIES_OK + 1))
    elif [ -n "$info_out" ]; then
        warn "Solo una arquitectura: $bin_name.framework"
        BINARIES_FAIL=$((BINARIES_FAIL + 1))
    fi
done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 2>/dev/null)

success "$BINARIES_OK binarios universales verificados."
[ "$BINARIES_FAIL" -gt 0 ] && warn "$BINARIES_FAIL binario(s) con arquitectura única."

# ── Resumen ───────────────────────────────────────────────────────────────────
APP_SIZE=$(du -sh "$APP_PATH" 2>/dev/null | cut -f1)

echo ""
echo -e "${BOLD}${GREEN}=========================================="
echo "  Build completado exitosamente!"
echo -e "==========================================${NC}"
echo -e "  Ubicación  : ${CYAN}$APP_PATH${NC}"
echo -e "  Tamaño     : $APP_SIZE"
echo -e "  Modo       : $BUILD_MODE"
echo -e "  Arquitecturas: arm64 (Apple Silicon) + x86_64 (Intel)"
echo -e "  Tiempo     : ${BUILD_TIME}s"
echo ""
echo -e "  Para ejecutar:"
echo -e "  ${CYAN}open $APP_PATH${NC}"
echo ""
