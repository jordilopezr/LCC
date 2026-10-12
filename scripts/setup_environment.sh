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
print_step "1/8: Instalando Git y herramientas básicas..."
if [ "$PKG_MANAGER" = "apt" ]; then
    sudo apt-get update
    sudo apt-get install -y git curl wget build-essential
elif [ "$PKG_MANAGER" = "dnf" ]; then
    sudo dnf install -y git curl wget make gcc gcc-c++
fi
print_success "Git y herramientas básicas instaladas"

# 1b. Instalar Linux toolchain (requerido por flutter doctor)
print_step "1b/8: Instalando Linux toolchain (clang, ninja, GTK3, glxinfo)..."
if [ "$PKG_MANAGER" = "apt" ]; then
    sudo apt-get install -y clang ninja-build libgtk-3-dev mesa-utils pkg-config
elif [ "$PKG_MANAGER" = "dnf" ]; then
    sudo dnf install -y clang ninja-build gtk3-devel glx-utils pkgconf-pkg-config
fi
print_success "Linux toolchain instalado"

# 2. Verificar si Flutter ya está instalado
print_step "2/8: Configurando Flutter SDK..."
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
print_step "3/8: Instalando Rust y Cargo..."
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

# Opcional: Google Cloud SDK (gcloud). NO es un paso obligatorio y por eso no
# lleva número: LCC ya no lo necesita para iniciar sesión.
print_step "Opcional: Google Cloud SDK (gcloud)"
echo "  LCC ya NO necesita gcloud para iniciar sesión: abre tu navegador y"
echo "  mantiene su propia sesión en el llavero del sistema. Tampoco lo usa"
echo "  para abrir túneles IAP ni reenviar puertos SSH."
echo "  Sigue siendo útil para dos cosas:"
echo "    - es el motor de autenticación alternativo (Ajustes → Método de"
echo "      inicio de sesión), si prefieres que LCC use la sesión de gcloud;"
echo "    - es la herramienta con la que ejecutas los comandos de"
echo "      administración que sugiere Doctor (habilitar APIs, regla de"
echo "      firewall de IAP, arrancar una VM). Doctor también da el enlace"
echo "      equivalente de la Cloud Console para cada uno."
echo

INSTALL_GCLOUD="no"
if command -v gcloud &> /dev/null; then
    print_warning "gcloud ya está instalado: $(gcloud --version | head -n 1)"
elif [ "${LCC_INSTALL_GCLOUD:-}" = "1" ]; then
    INSTALL_GCLOUD="yes"
elif [ "${LCC_INSTALL_GCLOUD:-}" = "0" ]; then
    print_warning "Omitido (LCC_INSTALL_GCLOUD=0)."
elif [ -t 0 ]; then
    read -r -p "¿Instalar Google Cloud SDK ahora? [s/N] " GCLOUD_ANSWER
    case "$GCLOUD_ANSWER" in
        [sSyY]*) INSTALL_GCLOUD="yes" ;;
        *) print_warning "Omitido. Puedes instalarlo más tarde si lo necesitas." ;;
    esac
else
    print_warning "Sin terminal interactiva: omitido. Usa LCC_INSTALL_GCLOUD=1 para instalarlo."
fi

if [ "$INSTALL_GCLOUD" = "yes" ]; then
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

# 4. Instalar dependencias del sistema
print_step "4/8: Instalando dependencias del sistema (libsecret, libjsoncpp, openssl)..."
if [ "$PKG_MANAGER" = "apt" ]; then
    sudo apt-get install -y libsecret-1-dev libjsoncpp-dev libssl-dev pkg-config
elif [ "$PKG_MANAGER" = "dnf" ]; then
    sudo dnf install -y libsecret-devel jsoncpp-devel openssl-devel pkgconf-pkg-config
fi
print_success "Dependencias del sistema instaladas"

# 5. Instalar Remmina
print_step "5/8: Instalando Remmina (cliente RDP)..."
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

# 6. Instalar flutter_rust_bridge_codegen
print_step "6/8: Instalando flutter_rust_bridge_codegen..."
source "$HOME/.cargo/env"
cargo install flutter_rust_bridge_codegen
print_success "flutter_rust_bridge_codegen instalado"

# 7. Instalar dependencias de Flutter del proyecto
print_step "7/8: Instalando dependencias de Flutter del proyecto..."
cd "$(dirname "$0")/.."
$HOME/flutter/bin/flutter pub get
print_success "Dependencias de Flutter instaladas"

# 8. Verificar instalación con flutter doctor
print_step "8/8: Verificando instalación con flutter doctor..."
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
echo "Inicio de sesión:"
echo "- Se hace desde la propia aplicación: añade una cuenta y LCC abrirá tu"
echo "  navegador para iniciar sesión en Google. No hace falta ejecutar ningún"
echo "  comando de gcloud."
echo
echo "Opcional:"
echo "- Si tienes gcloud y prefieres que LCC use su sesión, cámbialo en"
echo "  Ajustes → Método de inicio de sesión."
echo
