# Lightweight Cloud Connector (LCC) - Single Source of Truth (SSOT)

**Lightweight Cloud Connector (LCC)** es una aplicación de escritorio nativa para Linux (macOS previsto) diseñada para simplificar y asegurar la conexión a instancias de Google Cloud Platform (GCP) mediante **Identity-Aware Proxy (IAP)**.

Este documento consolida la documentación del proyecto (visión general, arquitectura, hojas de ruta y configuración técnica) en un único punto de referencia.

---

## 1. Arquitectura y Tecnologías

El proyecto sigue una arquitectura centrada en rendimiento, seguridad y experiencia multiplataforma:

*   **Frontend:** **Flutter (Dart)** para una UI reactiva multiplataforma, con gestión de estado mediante Riverpod (patrón Notifier).
*   **Backend / Core Logic:** **Rust** para el trabajo pesado: red, seguridad, clientes de GCP, túneles IAP, SFTP y diagnósticos.
*   **Bridge (FFI):** **[Flutter Rust Bridge 2.x](https://pub.dev/packages/flutter_rust_bridge)** para comunicación asíncrona de alto rendimiento entre Dart y Rust sin bloquear la UI. Los ficheros generados viven en `lib/src/bridge/api.dart/` y no deben editarse a mano.
*   **Almacenamiento:** `SharedPreferences` para preferencias y `libsecret` (D-Bus Secret Service) para almacenamiento local seguro de credenciales.
*   **Integración GCP (Dual API):** Capacidad de operar usando la interfaz de línea de comandos tradicional (`gcloud CLI`) o vía llamadas directas de API REST usando **Google Cloud Client Libraries** para mejoras de rendimiento (hasta 1.5x más rápido).

## 2. Modelo de Distribución

LCC es **100% gratuito y open source** (licencia MIT), con todas las funcionalidades disponibles sin restricciones. El antiguo modelo Free/Pro con validación de licencias Ed25519 fue eliminado por completo del código (ver `docs/cleanup_plan.md`, ejecutado): no existen `native/src/license.rs`, `license_provider.dart` ni `pro_gate.dart`.

---

## 3. Requisitos y Comandos de Desarrollo

### Requisitos del Sistema
1.  **Google Cloud SDK (`gcloud`)** configurado en el PATH.
2.  **Clientes RDP/VNC** instalados localmente (ej: Remmina).
3.  **Librerías C/C++ (Linux):** `libsecret-1-dev`, `libjsoncpp-dev`.
4.  Entorno de **Flutter** y **Rust** configurado con `cargo install flutter_rust_bridge_codegen`.

### Comandos Frecuentes
```bash
# 1. Regenerar Bridge Rust-Flutter (tras modificar native/src/api.rs)
flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root native --dart-output lib/src/bridge/api.dart

# 2. Compilar
flutter build linux --debug    # Debug local
flutter build linux --release  # Producción

# 3. Pruebas
cargo test                     # Backend Rust (ejecutar desde native/)
flutter test                   # Frontend Flutter

# 4. Monitoreo de logs locales
tail -f ~/.local/share/linux_cloud_connector/logs/app.log
```

### Empaquetado y Distribución
Los scripts de construcción están consolidados en `scripts/`:

```bash
scripts/setup_environment.sh      # Configura el entorno de desarrollo (Debian/Ubuntu/Fedora)
scripts/package_deb.sh            # Paquete .deb
scripts/package_rpm.sh            # Paquete .rpm
scripts/package_appimage.sh       # AppImage
scripts/package_tarball.sh        # Tarball genérico
scripts/build_all_containers.sh   # Builds reproducibles en contenedores podman (Ubuntu + AlmaLinux)
```

Definiciones de empaquetado adicionales en `packaging/` (`arch/PKGBUILD`, `podman/Containerfile.*`). Los artefactos se generan en `build_output/`.

## 4. Versionado

*   **Nombre de release:** `26H2` = segunda mitad de 2026. Esquema: `YYH1` / `YYH2`.
*   **Número de build:** formato fecha, ej. `20260715.1`.
*   **Release actual:** 26H2, build 20260715.1 (mostrado en el diálogo de Settings).
*   La versión de `pubspec.yaml` (`3.0.0+21`) es interna y no se expone públicamente.

---

## 5. Roadmap y Próximos Pasos

Objetivos principales para próximas iteraciones:

*   **Enterprise Auth & Cloud SQL:** Workforce Identity Federation (OIDC/SAML); automatización de Cloud SQL Auth Proxy e historial de conexiones recientes.
*   **UI Polish:** atajos de teclado y asistente de onboarding en el primer arranque.
*   **SSH Key Manager:** gestor visual de claves SSH y despliegue automático a metadatos u OS Login.
*   **Cost Monitor per VM:** resaltado de instancias costosas en ejecución prolongada (recomendación de idle).
*   **Startup Script Editor:** edición de startup scripts bash directamente desde la aplicación.
*   **Multi-Language (i18n):** ✅ **Completado (capa Dart) en 26H2U2** — UI Flutter migrada a diccionarios `gen-l10n` (`.arb`), plantilla EN + traducción ES completa (paridad de claves 666 = 666) y selector de idioma en Configuración. QA de layout en español verificado (suite automatizada `test/es_overflow_test.dart` sobre 8 diálogos + revisión manual de credenciales Windows y SSHFS). Pendiente: mapeo de códigos de error de Rust a claves localizadas y localización de las notificaciones de escritorio (`notification_service.dart`, sin locale accesible en contexto background — requiere cambio de arquitectura).

**Tareas Técnicas Prioritarias (Backlog)**
*   Resource Caching en memoria (TTL 5 min) para evitar exceso de peticiones a la API.
*   Navegador ligero nativo para Google Cloud Storage (GCS).
*   Soporte macOS (Intel/Apple Silicon). Windows queda **fuera de alcance** como plataforma anfitriona: ese terreno lo cubre [IAP Desktop](https://github.com/GoogleCloudPlatform/iap-desktop) de Google. (Las **VMs Windows** como destino —RDP, auto-credenciales— sí están soportadas.)

---

## 6. Historial de Versiones Destacado

Historial interno de desarrollo (las versiones v1.x–v3.x no se exponen públicamente; todo se distribuye como parte de la edición 26H2):

*   **v3.0.0+21:** VM Snapshot Manager (lista, crea, elimina). Migración de wrappers `gcloud` hacia REST directo (reqwest). Eliminación del modelo de licencias Free/Pro.
*   **v3.0.0:** Nuevo Dashboard y mejoras en la UI.
*   **v2.6.0:** Connectivity Doctor automatizado (10 checks) con reporte exportable y sanitizado.
*   **v2.5.0:** Montaje SSHFS (sistema de archivos de la VM en la máquina local).
*   **v2.4.0:** Auto-credenciales Windows con guardado en `libsecret`.
*   **v2.3.0:** Integración de clientes SQL (DBeaver, MySQL Workbench, pgAdmin, etc.).
*   **v2.2.0:** Consola serial, panel de diagnósticos y Audit Logs.
*   **v1.10.0:** VNC multi-cliente.
*   **v1.9.1:** Soporte RDP (Remmina, FreeRDP, KRDC, GNOME Connections).
*   **v1.7.0:** SFTP File Browser.

> El changelog público de la release actual se mantiene en la sección Changelog de `README.md`.

---
*Documento consolidado del proyecto LCC. Útil para entender rápidamente arquitectura, diseño y objetivos de desarrollo.*
