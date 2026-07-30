#!/bin/bash

# Configuración
APP_NAME="lightweight-cloud-connector" # Debian prefiere guiones
BINARY_NAME="lightweight_cloud_connector"
VERSION="${VERSION:-26H2}"
ARCH="amd64"
MAINTAINER="Jordi Lopez Reyes <aim@jordilopezr.com>"
DESCRIPTION="Native Google Cloud IAP Connector for Linux"
DEPENDENCIES="libgtk-3-0, liblzma5, libsecret-1-0, remmina" # Remmina es vital; libsecret para flutter_secure_storage

# Cambiar al directorio raíz del proyecto
cd "$(dirname "$0")/.."

echo "🚀 Iniciando empaquetado para $APP_NAME v$VERSION..."

# 1. Limpiar y Compilar (Release)
echo "📦 Compilando Flutter Release..."
flutter clean
flutter pub get
# NOTA: el bridge de flutter_rust_bridge está commiteado (native/src/frb_generated.rs
# + lib/src/bridge/api.dart/) y se regenera en DESARROLLO, no al empaquetar.
# Regenerarlo aquí desincronizaba el bridge del libnative.so compilado
# (content-hash mismatch → la app fallaba en RustLib.init y no arrancaba).
# Compilar
flutter build linux --release

if [ $? -ne 0 ]; then
    echo "❌ Error en la compilación. Abortando."
    exit 1
fi

# 2. Preparar estructura de directorios
echo "📂 Creando estructura de directorios..."
BUILD_DIR="build_deb"
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR/DEBIAN
mkdir -p $BUILD_DIR/usr/bin
mkdir -p $BUILD_DIR/usr/lib/$APP_NAME
mkdir -p $BUILD_DIR/usr/share/applications
mkdir -p $BUILD_DIR/usr/share/icons/hicolor/128x128/apps

# 3. Copiar archivos de la compilación
SOURCE_BUNDLE="build/linux/x64/release/bundle"
cp -r $SOURCE_BUNDLE/* $BUILD_DIR/usr/lib/$APP_NAME/

# 4. Crear script de lanzamiento en /usr/bin
cat <<EOF > $BUILD_DIR/usr/bin/$APP_NAME
#!/bin/bash
exec /usr/lib/$APP_NAME/$BINARY_NAME "\$@"
EOF
chmod +x $BUILD_DIR/usr/bin/$APP_NAME

# 5. Crear archivo .desktop (Menú de aplicaciones)
cat <<EOF > $BUILD_DIR/usr/share/applications/$APP_NAME.desktop
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

# 6. Icono (Usamos el logo de Flutter por defecto si no hay otro, o copiamos el del proyecto)
# Intentamos buscar el icono en resources, si no, generamos uno dummy o copiamos el asset
if [ -f "linux/runner/resources/app_icon.png" ]; then
    cp "linux/runner/resources/app_icon.png" "$BUILD_DIR/usr/share/icons/hicolor/128x128/apps/$APP_NAME.png"
else
    # Fallback si no tienes un icono customizado aún
    echo "⚠️ No se encontró icono personalizado, usando placeholder."
    touch "$BUILD_DIR/usr/share/icons/hicolor/128x128/apps/$APP_NAME.png"
fi

# 7. Crear archivo CONTROL (Metadatos)
# Calculamos tamaño instalado (en KB)
INSTALLED_SIZE=$(du -s $BUILD_DIR/usr | cut -f1)

cat <<EOF > $BUILD_DIR/DEBIAN/control
Package: $APP_NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $INSTALLED_SIZE
Depends: $DEPENDENCIES
Section: utils
Priority: optional
Description: $DESCRIPTION
 Una herramienta nativa para conectar a instancias de Google Cloud Platform (GCP)
 mediante Identity-Aware Proxy (IAP) de forma segura.
 Incluye soporte para RDP (Remmina) y SSH.
EOF

# 7b. Script postinst: refrescar la base de datos de aplicaciones y la caché de
# iconos tras instalar (paridad con el %post del RPM). Sin esto, algunos
# entornos de escritorio no registran/actualizan la entrada de menú hasta
# reiniciar la sesión.
cat <<'EOF' > $BUILD_DIR/DEBIAN/postinst
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 $BUILD_DIR/DEBIAN/postinst

# 8. Construir el .deb
echo "🔨 Construyendo paquete .deb..."
dpkg-deb --root-owner-group --build $BUILD_DIR "${APP_NAME}_${VERSION}_${ARCH}.deb"

echo "✅ ¡Éxito! Paquete creado: ${APP_NAME}_${VERSION}_${ARCH}.deb"
echo "👉 Para instalar: sudo dpkg -i ${APP_NAME}_${VERSION}_${ARCH}.deb"
