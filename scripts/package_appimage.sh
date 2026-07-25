#!/bin/bash

# Configuración
APP_NAME="lightweight-cloud-connector"
BINARY_NAME="lightweight_cloud_connector"
VERSION="26H2"
ARCH="x86_64"
MAINTAINER="Jordi Lopez Reyes <aim@jordilopezr.com>"
DESCRIPTION="Native Google Cloud IAP Connector for Linux"

# Cambiar al directorio raíz del proyecto
cd "$(dirname "$0")/.."

echo "🚀 Iniciando empaquetado AppImage para $APP_NAME v$VERSION..."

# Verificar que appimagetool esté disponible
APPIMAGETOOL=$(which appimagetool 2>/dev/null || ls ~/bin/appimagetool* 2>/dev/null | head -1)
if [ -z "$APPIMAGETOOL" ]; then
    echo "❌ appimagetool no encontrado."
    echo "   Descárgalo desde: https://github.com/AppImage/appimagetool/releases/tag/continuous"
    echo "   Ejemplo: wget -O ~/bin/appimagetool https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage && chmod +x ~/bin/appimagetool"
    exit 1
fi

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

# 2. Preparar AppDir
echo "📂 Creando AppDir..."
APPDIR="build_appimage/${APP_NAME}.AppDir"
rm -rf build_appimage
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib/$APP_NAME"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/128x128/apps"

# 3. Copiar archivos de la compilación
SOURCE_BUNDLE="build/linux/x64/release/bundle"
cp -r $SOURCE_BUNDLE/* "$APPDIR/usr/lib/$APP_NAME/"

# 4. Script de lanzamiento en usr/bin
cat <<EOF > "$APPDIR/usr/bin/$APP_NAME"
#!/bin/bash
exec "\$(dirname "\$(readlink -f "\$0")")/../lib/$APP_NAME/$BINARY_NAME" "\$@"
EOF
chmod +x "$APPDIR/usr/bin/$APP_NAME"

# 5. AppRun (punto de entrada del AppImage)
cat <<EOF > "$APPDIR/AppRun"
#!/bin/bash
HERE="\$(dirname "\$(readlink -f "\$0")")"
export LD_LIBRARY_PATH="\$HERE/usr/lib/$APP_NAME/lib:\$LD_LIBRARY_PATH"
exec "\$HERE/usr/lib/$APP_NAME/$BINARY_NAME" "\$@"
EOF
chmod +x "$APPDIR/AppRun"

# 6. Archivo .desktop
cat <<EOF > "$APPDIR/$APP_NAME.desktop"
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

# También en la ruta estándar
cp "$APPDIR/$APP_NAME.desktop" "$APPDIR/usr/share/applications/$APP_NAME.desktop"

# 7. Icono
if [ -f "linux/runner/resources/app_icon.png" ]; then
    cp "linux/runner/resources/app_icon.png" "$APPDIR/$APP_NAME.png"
    cp "linux/runner/resources/app_icon.png" "$APPDIR/usr/share/icons/hicolor/128x128/apps/$APP_NAME.png"
else
    echo "⚠️ No se encontró icono personalizado, usando placeholder."
    touch "$APPDIR/$APP_NAME.png"
    touch "$APPDIR/usr/share/icons/hicolor/128x128/apps/$APP_NAME.png"
fi

# 8. Construir el AppImage
echo "🔨 Construyendo AppImage..."
OUTPUT_FILE="${APP_NAME}_${VERSION}_${ARCH}.AppImage"
ARCH=$ARCH "$APPIMAGETOOL" "$APPDIR" "$OUTPUT_FILE"

if [ $? -eq 0 ]; then
    echo "✅ ¡Éxito! AppImage creado: $OUTPUT_FILE"
    echo "👉 Para ejecutar: chmod +x $OUTPUT_FILE && ./$OUTPUT_FILE"
else
    echo "❌ Error al crear el AppImage."
    exit 1
fi
