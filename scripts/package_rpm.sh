#!/bin/bash

# Configuración
APP_NAME="lightweight-cloud-connector"
BINARY_NAME="lightweight_cloud_connector"
VERSION="${VERSION:-26H2}"
# RPM's Version: field forbids '-' (it separates version from release). Map any
# '-' (e.g. a pre-release suffix like 26H2u1-rc1) to '~', which RPM allows and
# orders as a pre-release. Route '~' through a variable so it is not
# tilde-expanded. Other formats (deb/AppImage/tarball) keep '-'.
_rpm_tilde='~'
VERSION="${VERSION//-/${_rpm_tilde}}"
RELEASE="1"
ARCH="x86_64"
MAINTAINER="Jordi Lopez Reyes <aim@jordilopezr.com>"
DESCRIPTION="Native Google Cloud IAP Connector for Linux"
DEPENDENCIES="gtk3, xz-libs, libsecret, remmina"

# Cambiar al directorio raíz del proyecto
cd "$(dirname "$0")/.."

# Cargar automáticamente Flutter y Cargo en el PATH si no están presentes
if ! command -v flutter &>/dev/null && [ -d "$HOME/flutter/bin" ]; then
    export PATH="$HOME/flutter/bin:$PATH"
fi
if ! command -v cargo &>/dev/null && [ -f "$HOME/.cargo/env" ]; then
    source "$HOME/.cargo/env"
fi

echo "🚀 Iniciando empaquetado RPM para $APP_NAME v$VERSION..."

# Verificar que rpmbuild esté disponible
if ! command -v rpmbuild &>/dev/null; then
    echo "❌ rpmbuild no encontrado."
    echo "   Instálalo con: sudo dnf install rpm-build"
    exit 1
fi

# 1. Limpiar y Compilar (Release)
echo "📦 Compilando Flutter Release..."
flutter clean
flutter pub get
# NOTA: el bridge de flutter_rust_bridge está commiteado (native/src/frb_generated.rs
# + lib/src/bridge/api.dart/) y se regenera en DESARROLLO, no al empaquetar.
# Regenerarlo aquí desincronizaba el bridge del libnative.so compilado
# (content-hash mismatch → la app fallaba en RustLib.init y no arrancaba).
flutter build linux --release

if [ $? -ne 0 ]; then
    echo "❌ Error en la compilación. Abortando."
    exit 1
fi

# 2. Preparar estructura de directorios para rpmbuild
echo "📂 Creando estructura rpmbuild..."
BUILD_ROOT="build_rpm"
RPM_BUILD_DIR="$BUILD_ROOT/rpmbuild"
BUILDROOT="$RPM_BUILD_DIR/BUILDROOT/${APP_NAME}-${VERSION}-${RELEASE}.${ARCH}"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILDROOT/usr/bin"
mkdir -p "$BUILDROOT/usr/lib/$APP_NAME"
mkdir -p "$BUILDROOT/usr/share/applications"
mkdir -p "$BUILDROOT/usr/share/icons/hicolor/128x128/apps"
mkdir -p "$RPM_BUILD_DIR/SPECS"
mkdir -p "$RPM_BUILD_DIR/RPMS"
mkdir -p "$RPM_BUILD_DIR/SRPMS"
mkdir -p "$RPM_BUILD_DIR/BUILD"
mkdir -p "$RPM_BUILD_DIR/SOURCES"

# 3. Copiar archivos de la compilación
SOURCE_BUNDLE="build/linux/x64/release/bundle"
cp -r $SOURCE_BUNDLE/* "$BUILDROOT/usr/lib/$APP_NAME/"

# 4. Crear script de lanzamiento en /usr/bin
cat <<EOF > "$BUILDROOT/usr/bin/$APP_NAME"
#!/bin/bash
exec /usr/lib/$APP_NAME/$BINARY_NAME "\$@"
EOF
chmod +x "$BUILDROOT/usr/bin/$APP_NAME"

# 5. Crear archivo .desktop
cat <<EOF > "$BUILDROOT/usr/share/applications/$APP_NAME.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Lightweight Cloud Connector
Comment=$DESCRIPTION
Exec=$APP_NAME
Icon=$APP_NAME
Categories=Development;Network;Utility;
Terminal=false
StartupNotify=true
StartupWMClass=com.lightweight_cloud_connector
EOF

# 6. Icono
if [ -f "linux/runner/resources/app_icon.png" ]; then
    cp "linux/runner/resources/app_icon.png" "$BUILDROOT/usr/share/icons/hicolor/128x128/apps/$APP_NAME.png"
else
    echo "⚠️ No se encontró icono personalizado, usando placeholder."
    touch "$BUILDROOT/usr/share/icons/hicolor/128x128/apps/$APP_NAME.png"
fi

# 7. Crear el archivo .spec
cat <<EOF > "$RPM_BUILD_DIR/SPECS/$APP_NAME.spec"
Name:           $APP_NAME
Version:        $VERSION
Release:        ${RELEASE}%{?dist}
Summary:        $DESCRIPTION
License:        Proprietary
BuildArch:      $ARCH

# Disable RPATH check because Flutter plugins contain ephemeral paths
%define __brp_check_rpaths %{nil}

Requires:       $DEPENDENCIES

%description
Una herramienta nativa para conectar a instancias de Google Cloud Platform (GCP)
mediante Identity-Aware Proxy (IAP) de forma segura.
Incluye soporte para RDP (Remmina) y SSH.

%install
cp -r %{_topdir}/BUILDROOT/${APP_NAME}-${VERSION}-${RELEASE}.${ARCH}/* %{buildroot}/

%files
/usr/bin/$APP_NAME
/usr/lib/$APP_NAME/
/usr/share/applications/$APP_NAME.desktop
/usr/share/icons/hicolor/128x128/apps/$APP_NAME.png

%post
gtk-update-icon-cache /usr/share/icons/hicolor &>/dev/null || true
update-desktop-database &>/dev/null || true

%postun
gtk-update-icon-cache /usr/share/icons/hicolor &>/dev/null || true
update-desktop-database &>/dev/null || true
EOF

# 8. Construir el RPM
echo "🔨 Construyendo paquete RPM..."
rpmbuild --define "_topdir $(pwd)/$RPM_BUILD_DIR" \
         --define "%_buildroot $(pwd)/$BUILDROOT" \
         -bb "$RPM_BUILD_DIR/SPECS/$APP_NAME.spec"

if [ $? -eq 0 ]; then
    RPM_FILE=$(find "$RPM_BUILD_DIR/RPMS" -name "*.rpm" | head -1)
    cp "$RPM_FILE" "${APP_NAME}-${VERSION}-${RELEASE}.${ARCH}.rpm"
    echo "✅ ¡Éxito! Paquete creado: ${APP_NAME}-${VERSION}-${RELEASE}.${ARCH}.rpm"
    echo "👉 Para instalar: sudo dnf install ${APP_NAME}-${VERSION}-${RELEASE}.${ARCH}.rpm"
else
    echo "❌ Error al crear el RPM."
    exit 1
fi
