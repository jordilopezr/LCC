#!/bin/bash

# Script de configuración del ambiente de desarrollo para LCC en macOS
# Adaptado para macOS Tahoe (15+)

set -e

echo "=========================================="
echo "Configuración del Ambiente LCC - macOS"
echo "=========================================="

# Colores
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_step() { echo -e "${BLUE}==>${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

# 1. Verificar/Instalar Homebrew
print_step "1. Verificando Homebrew..."
if ! command -v brew &> /dev/null; then
    print_step "Instalando Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
    print_success "Homebrew ya está instalado"
fi

# 2. Instalar dependencias del sistema
print_step "2. Instalando dependencias de sistema via Homebrew..."
brew install git curl wget pkg-config openssl@3 cmake ninja
print_success "Dependencias instaladas"

# 3. Configurar Rust
print_step "3. Configurando Rust..."
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
else
    print_success "Rust ya está instalado: $(rustc --version)"
fi

# Instalar flutter_rust_bridge_codegen v2
print_step "Instalando flutter_rust_bridge_codegen..."
cargo install flutter_rust_bridge_codegen --version 2.11.1
print_success "FRB Codegen instalado"

# 4. Configurar Flutter
print_step "4. Configurando Flutter..."
if ! command -v flutter &> /dev/null; then
    print_warning "Flutter no encontrado en PATH. Descargando..."
    cd "$HOME"
    git clone https://github.com/flutter/flutter.git -b stable
    export PATH="$PATH:$HOME/flutter/bin"
    echo 'export PATH="$PATH:$HOME/flutter/bin"' >> ~/.zshrc
else
    print_success "Flutter encontrado: $(flutter --version | head -n 1)"
fi

# Habilitar soporte para macOS desktop
flutter config --enable-macos-desktop

# 5. CocoaPods (Necesario para macOS)
print_step "5. Instalando CocoaPods..."
if ! command -v pod &> /dev/null; then
    brew install cocoapods
else
    print_success "CocoaPods ya instalado"
fi

# 6. Google Cloud SDK
print_step "6. Instalando Google Cloud CLI..."
if ! command -v gcloud &> /dev/null; then
    brew install --cask google-cloud-sdk
else
    print_success "gcloud CLI ya instalado"
fi

# 7. Preparar Proyecto
print_step "7. Preparando dependencias del proyecto..."
cd "$(dirname "$0")/.."
flutter pub get

# 8. Generar Bridge
print_step "8. Generando código del bridge (FRB v2)..."
flutter_rust_bridge_codegen generate
print_success "Bridge generado"

echo ""
echo "=========================================="
echo -e "${GREEN}✓ Entorno preparado con éxito!${NC}"
echo "=========================================="
echo "Ejecuta 'source ~/.zshrc' si es tu primera vez instalando Flutter/Rust."
echo "Para compilar: ./scripts/build_macos.sh"
