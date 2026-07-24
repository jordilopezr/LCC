#!/bin/bash

# Script de configuración del ambiente de desarrollo para Lightweight Cloud Connector
# Autor: Jordi Lopez Reyes

set -e

echo "=========================================="
echo "Configuración del Ambiente de Desarrollo"
echo "Lightweight Cloud Connector"
echo "=========================================="
echo

# Colores para output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Función para imprimir mensajes
print_step() {
    echo -e "${BLUE}==>${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Detectar gestor de paquetes
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
else
    echo -e "${YELLOW}Error: No se pudo detectar un gestor de paquetes soportado (apt-get o dnf).${NC}"
    exit 1
fi

# 1. Actualizar sistema e instalar dependencias básicas
print_step "1/9: Instalando Git y herramientas básicas..."
if [ "$PKG_MANAGER" = "apt" ]; then
    sudo apt-get update
    sudo apt-get install -y git curl wget build-essential
elif [ "$PKG_MANAGER" = "dnf" ]; then
    sudo dnf install -y git curl wget make gcc gcc-c++
fi
print_success "Git y herramientas básicas instaladas"

# 1b. Instalar Linux toolchain (requerido por flutter doctor)
print_step "1b/9: Instalando Linux toolchain (clang, ninja, GTK3, glxinfo)..."
if [ "$PKG_MANAGER" = "apt" ]; then
    sudo apt-get install -y clang ninja-build libgtk-3-dev mesa-utils pkg-config
elif [ "$PKG_MANAGER" = "dnf" ]; then
    sudo dnf install -y clang ninja-build gtk3-devel glx-utils pkgconf-pkg-config
fi
print_success "Linux toolchain instalado"

# 2. Verificar si Flutter ya está instalado
print_step "2/9: Configurando Flutter SDK..."
if [ -d "$HOME/flutter" ]; then
    print_warning "Flutter ya está en $HOME/flutter"
else
    print_step "Descargando Flutter SDK..."
    cd "$HOME"
    git clone https://github.com/flutter/flutter.git -b stable
    print_success "Flutter SDK descargado"
fi

# Agregar Flutter al PATH si no está
if ! grep -q 'flutter/bin' ~/.bashrc; then
    echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc
    print_success "Flutter agregado al PATH en ~/.bashrc"
fi
export PATH="$HOME/flutter/bin:$PATH"

# Ejecutar flutter doctor para descargar dependencias
$HOME/flutter/bin/flutter doctor
print_success "Flutter SDK configurado"

# 3. Instalar Rust
print_step "3/9: Instalando Rust y Cargo..."
if command -v rustc &> /dev/null; then
    print_warning "Rust ya está instalado: $(rustc --version)"
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
    print_success "Rust y Cargo instalados"
fi

# Agregar Cargo al PATH si no está
if ! grep -q '.cargo/env' ~/.bashrc; then
    echo 'source "$HOME/.cargo/env"' >> ~/.bashrc
    print_success "Cargo agregado al PATH"
fi

# 4. Instalar Google Cloud SDK
print_step "4/9: Instalando Google Cloud SDK (gcloud)..."
if command -v gcloud &> /dev/null; then
    print_warning "gcloud ya está instalado: $(gcloud --version | head -n 1)"
else
    # Instalar gcloud CLI
    if [ "$PKG_MANAGER" = "apt" ]; then
        echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
        sudo apt-get install -y apt-transport-https ca-certificates gnupg
        curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
        sudo apt-get update
        sudo apt-get install -y google-cloud-cli
    elif [ "$PKG_MANAGER" = "dnf" ]; then
        sudo tee /etc/yum.repos.d/google-cloud-sdk.repo << EOM
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el8-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM
        sudo dnf install -y google-cloud-cli
    fi
    print_success "Google Cloud SDK instalado"
fi

# 5. Instalar dependencias del sistema
print_step "5/9: Instalando dependencias del sistema (libsecret, libjsoncpp, openssl)..."
if [ "$PKG_MANAGER" = "apt" ]; then
    sudo apt-get install -y libsecret-1-dev libjsoncpp-dev libssl-dev pkg-config
elif [ "$PKG_MANAGER" = "dnf" ]; then
    sudo dnf install -y libsecret-devel jsoncpp-devel openssl-devel pkgconf-pkg-config
fi
print_success "Dependencias del sistema instaladas"

# 6. Instalar Remmina
print_step "6/9: Instalando Remmina (cliente RDP)..."
if command -v remmina &> /dev/null; then
    print_warning "Remmina ya está instalado: $(remmina --version)"
else
    if [ "$PKG_MANAGER" = "apt" ]; then
        sudo apt-get install -y remmina remmina-plugin-rdp remmina-plugin-vnc
    elif [ "$PKG_MANAGER" = "dnf" ]; then
        sudo dnf install -y remmina remmina-plugins-rdp remmina-plugins-vnc
    fi
    print_success "Remmina instalado"
fi

# 7. Instalar flutter_rust_bridge_codegen
print_step "7/9: Instalando flutter_rust_bridge_codegen..."
source "$HOME/.cargo/env"
cargo install flutter_rust_bridge_codegen
print_success "flutter_rust_bridge_codegen instalado"

# 8. Instalar dependencias de Flutter del proyecto
print_step "8/9: Instalando dependencias de Flutter del proyecto..."
cd "$(dirname "$0")/.."
$HOME/flutter/bin/flutter pub get
print_success "Dependencias de Flutter instaladas"

# 9. Verificar instalación con flutter doctor
print_step "9/9: Verificando instalación con flutter doctor..."
$HOME/flutter/bin/flutter doctor
print_success "Verificación completada"

echo
echo "=========================================="
echo -e "${GREEN}✓ Configuración completada exitosamente!${NC}"
echo "=========================================="
echo
echo "Próximos pasos:"
echo "1. Cierra y abre una nueva terminal para cargar el PATH actualizado"
echo "2. Genera el bridge Rust-Flutter:"
echo "   flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root native --dart-output lib/src/bridge/api.dart"
echo "3. Ejecuta la aplicación:"
echo "   flutter run -d linux"
echo
echo "Configuración opcional:"
echo "- Para usar Google Cloud Client Libraries (mejor rendimiento):"
echo "  gcloud auth application-default login"
echo
