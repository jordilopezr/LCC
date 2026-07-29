#!/bin/bash

# Configuración
APP_NAME="lightweight-cloud-connector"
# Nombre del ejecutable que produce el build de Flutter (ver linux/CMakeLists.txt)
BINARY_NAME="lightweight_cloud_connector"
VERSION="${VERSION:-26H2}"
ARCH="amd64"

# Cambiar al directorio raíz del proyecto
cd "$(dirname "$0")/.."

echo "🚀 Iniciando empaquetado Tarball para $APP_NAME v$VERSION..."

# 1. Limpiar y Compilar (Release)
echo "📦 Compilando Flutter Release..."
flutter clean
flutter pub get
flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root native --dart-output lib/src/bridge/api.dart
flutter build linux --release

if [ $? -ne 0 ]; then
    echo "❌ Error en la compilación. Abortando."
    exit 1
fi

# 2. Preparar estructura de directorios
echo "📂 Creando estructura de directorios..."
BUILD_DIR="build_tarball"
rm -rf $BUILD_DIR
mkdir -p $BUILD_DIR/$APP_NAME

# 3. Copiar archivos de la compilación
SOURCE_BUNDLE="build/linux/x64/release/bundle"
# Copiamos solo lo necesario (binario, data y lib). Ignoramos archivos temporales si los hubiera.
cp -r $SOURCE_BUNDLE/data $BUILD_DIR/$APP_NAME/
cp -r $SOURCE_BUNDLE/lib $BUILD_DIR/$APP_NAME/
# Copiar y renombrar el binario
cp $SOURCE_BUNDLE/$BINARY_NAME $BUILD_DIR/$APP_NAME/$APP_NAME

# 4. Limpiar archivos innecesarios
echo "🧹 Limpiando archivos innecesarios..."
find $BUILD_DIR/$APP_NAME -name "*.dbg" -delete 2>/dev/null
find $BUILD_DIR/$APP_NAME -name "*.DS_Store" -delete 2>/dev/null

# Archivo .desktop de ejemplo para que el usuario pueda instalarlo
cat <<EOF > $BUILD_DIR/$APP_NAME/$APP_NAME.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Lightweight Cloud Connector
Comment=Native Google Cloud IAP Connector for Linux
Exec=bash -c "\"\$(dirname %k)/$APP_NAME\""
Icon=utilities-terminal
Categories=Development;Network;Utility;
Terminal=false
StartupNotify=true
StartupWMClass=com.lightweight_cloud_connector
EOF
chmod +x $BUILD_DIR/$APP_NAME/$APP_NAME.desktop

# Copiar el icono
if [ -f "linux/runner/resources/app_icon.png" ]; then
    cp "linux/runner/resources/app_icon.png" "$BUILD_DIR/$APP_NAME/icon.png"
fi

# 5. Comprimir
echo "🔨 Comprimiendo en tar.gz..."
cd $BUILD_DIR
TAR_NAME="${APP_NAME}_${VERSION}_${ARCH}.tar.gz"
tar -czf "$TAR_NAME" $APP_NAME/

cd ..
mv "$BUILD_DIR/$TAR_NAME" .
rm -rf "$BUILD_DIR"

echo "✅ ¡Éxito! Tarball creado: $TAR_NAME"
echo "👉 El usuario solo necesita extraerlo y ejecutar ./$APP_NAME.sh o hacer doble clic en $APP_NAME.desktop"
