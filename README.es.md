# Lightweight Cloud Connector (LCC)

🇬🇧 [Read in English](README.md)

**Lightweight Cloud Connector** es una aplicación de escritorio nativa multiplataforma diseñada para simplificar y asegurar la conexión a instancias de Google Cloud Platform (GCP) mediante **Identity-Aware Proxy (IAP)**.

Desarrollada por **Jordi Lopez Reyes** con **Flutter** y **Rust** para un rendimiento y seguridad óptimos. LCC es **100% gratuito y open source** (licencia MIT), con todas las funcionalidades disponibles sin restricciones.

![Release](https://img.shields.io/badge/Release-26H2-brightgreen)
![Build](https://img.shields.io/badge/Build-20260715.1-blue)
![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20(pr%C3%B3ximamente)-blue)
![License](https://img.shields.io/badge/License-MIT-purple)

<img width="1332" height="819" alt="Panel principal de LCC" src="https://github.com/user-attachments/assets/76d627da-e9a8-45c5-ab79-965b6dd3440c" />
<img width="1332" height="819" alt="Gestión de túneles en LCC" src="https://github.com/user-attachments/assets/9c2cb83f-d770-47b4-b0d5-be40897a2012" />

## Características

### VM Snapshot Manager
*   **Listar snapshots:** visualiza todos los snapshots del proyecto con nombre, estado, tamaño de disco y almacenamiento.
*   **Crear snapshot:** crea snapshots de cualquier disco de una VM con nombre personalizable.
*   **Eliminar snapshot:** elimina snapshots individuales con confirmación.
*   **Información de tamaño:** muestra `diskSizeGb` y `storageBytes` con formato legible (GB/MB).
*   **Backend Rust:** operaciones CRUD de snapshots implementadas de forma nativa en Rust vía GCP REST API.

### Multi-Account Management
*   **Múltiples cuentas GCP:** gestiona varias cuentas de Google Cloud desde una sola interfaz.
*   **Cambio rápido:** cambia entre cuentas sin salir de la aplicación.
*   **Autenticación independiente:** cada cuenta mantiene sus propias credenciales.
*   **Lista de cuentas:** vista clara de todas las cuentas configuradas con estado de autenticación.

### Tunnel Manager y Auto-Reconnect
*   **Vista consolidada:** panel centralizado con todos los túneles activos de todas las VMs.
*   **Túnel nativo:** los túneles IAP se establecen de forma nativa en Rust, sin lanzar el binario `gcloud`, con fallback automático al motor `gcloud` si el camino nativo falla.
*   **Auto-reconnect:** reconecta automáticamente túneles caídos sin intervención manual.
*   **Gestión individual:** desconecta, reconecta o inspecciona cada túnel por separado.
*   **Health monitoring:** estado de salud en tiempo real (proceso + puerto TCP) cada 30 segundos.
*   **Alertas de caída:** notificaciones inmediatas cuando un túnel se cae inesperadamente.

### OS Login, VM Labels y Suspend/Resume
*   **OS Login:** soporte para autenticación OS Login en lugar de metadata SSH keys.
*   **VM Labels:** visualiza y filtra instancias por etiquetas GCP.
*   **Suspend/Resume:** suspende y reanuda VMs (además de start/stop/reset).

### Connectivity Doctor
*   **10 checks automáticos:** diagnostica problemas de conectividad agrupados en 5 categorías.
*   **Authentication:** verifica gcloud CLI, cuenta activa y credenciales ADC.
*   **Project & Permissions:** verifica acceso al proyecto y APIs habilitadas (Compute, IAP).
*   **IAP & Network:** verifica la API de IAP y reglas de firewall para `35.235.240.0/20`.
*   **VM Status:** verifica estado de la VM y guest agent.
*   **Local Environment:** detecta clientes remotos instalados (SSH, RDP, VNC).
*   **Fix suggestions:** sugerencias con comandos copiables para resolver cada problema.
*   **Auto-fix:** acciones automáticas como re-autenticación o inicio de VM (con confirmación).
*   **Export report:** genera un reporte Markdown con datos sensibles redactados automáticamente.
*   **Re-run:** ejecuta los checks de nuevo después de aplicar fixes.

### Soporte Multi-Cliente RDP
*   **4 clientes soportados:** Remmina, FreeRDP (xfreerdp), KRDC, GNOME Connections.
*   **Fallback automático:** si el cliente preferido no está disponible, intenta otros automáticamente.
*   **Configuración persistente:** selecciona tu cliente RDP favorito en Settings.
*   **Detección automática:** identifica qué clientes están instalados en el sistema.
*   **Soporte completo de características:** fullscreen, resolución personalizada, credenciales, ignorar certificados.
*   **Remmina config files:** soporte para archivos `.remmina` con permisos seguros (0600).

### Soporte Multi-Cliente VNC
*   **4 clientes soportados:** Remmina, TigerVNC (vncviewer), KRDC, Vinagre.
*   **Fallback automático:** fallback inteligente si el cliente preferido no está disponible.
*   **Configuración flexible:** calidad (High/Medium/Low/Auto), fullscreen, view-only, resolución personalizada.
*   **Detección automática:** identifica qué clientes VNC están instalados (nativo + Flatpak).
*   **Config files seguros:** archivos de contraseña con permisos 0600 y limpieza automática.
*   **Gestión de puertos:** conversión automática entre display number (:0, :1) y puerto (5900, 5901).

### SFTP File Transfer Browser
*   **Navegador de archivos:** interfaz gráfica completa para explorar archivos remotos vía SFTP.
*   **Upload:** sube archivos locales a la instancia remota con progreso visual.
*   **Download:** descarga archivos desde la instancia a la máquina local.
*   **Gestión de directorios:** crea carpetas y elimina archivos o directorios remotos.
*   **Transferencia segura:** conexiones SFTP sobre túneles SSH IAP (puerto 22).
*   **Auto-tunnel:** crea automáticamente el túnel SSH si no existe al abrir el navegador.
*   **Formato de tamaños:** formateo automático (B, KB, MB, GB).

### Port Forwarding Genérico y Multi-Tunnel
*   **Soporte universal:** conecta a cualquier servicio TCP vía IAP (PostgreSQL, MySQL, HTTP, Redis, MongoDB, etc.).
*   **Túneles simultáneos:** múltiples túneles por VM.
*   **Custom tunnel dialog:** 8 presets de servicios comunes más entrada de puerto personalizado.
*   **Gestión individual:** desconecta túneles específicos sin afectar a los demás.

### Notificaciones Desktop
*   **Notificaciones nativas** para eventos importantes.
*   **Cambios de estado de VM:** alertas automáticas cuando las VMs cambian entre RUNNING y STOPPED.
*   **Alertas de túneles IAP:** notificación inmediata cuando un túnel se cae inesperadamente.
*   **Operaciones de ciclo de vida:** notificaciones de éxito o fallo en start/stop/reset.

### Configuración Personalizable
*   **Settings dialog:** panel de configuración completo y organizado.
*   **Intervalos de auto-refresh:** 10s, 30s, 60s, 120s, 300s, o personalizado 5–600s.
*   **Tema:** Light / Dark / System.
*   **Idioma:** español e inglés. Por defecto sigue el idioma del sistema; se puede forzar desde Settings y el cambio se aplica al instante, sin reiniciar.
*   **Persistencia:** todas las configuraciones se guardan entre sesiones.

### Multi-idioma (i18n)
*   **Español e inglés:** interfaz completa traducida (~666 claves, paridad verificada entre ambos idiomas).
*   **Detección automática:** usa el idioma del sistema operativo por defecto.
*   **Cambio en caliente:** el selector de Settings aplica el idioma sin reiniciar la aplicación.
*   **Base estándar:** `gen-l10n` de Flutter con diccionarios `.arb`, lo que facilita añadir más idiomas.
*   **Nota:** los errores del túnel IAP usan códigos tipados y están traducidos (EN/ES). El resto de mensajes de error generados en Rust (`doctor`, `sftp`, `snapshots`, `gcloud`) y las notificaciones de escritorio siguen en inglés (pendiente para una versión futura).

### Integración con Google Cloud Client Libraries
*   **Dual API:** alterna entre gcloud CLI y Google Cloud Client Libraries (REST API).
*   **Rendimiento:** las Client Libraries son 1.3–1.5x más rápidas que la CLI.
*   **Cambio en caliente:** toggle en el AppBar para cambiar entre métodos en tiempo real.

### Gestión del Ciclo de Vida de VMs
*   **Start / Stop / Reset / Suspend / Resume.**
*   **Indicadores de estado:** botones habilitados o deshabilitados según el estado actual de la VM.

### Observabilidad y Monitoreo
*   **Logging estructurado:** sistema persistente con rotación automática (10 MB, 5 archivos).
*   **Export logs:** botón en la UI para exportar logs consolidados.
*   **Dashboard de métricas:** uptime, última verificación y estado de salud en tiempo real.

### Seguridad y Fiabilidad
*   **Validación de entradas:** protección contra inyección de comandos mediante validación regex.
*   **Timeouts:** todos los comandos gcloud tienen timeout de 10 s.
*   **Monitoreo de salud:** verificación automática de túneles cada 30 segundos (proceso + puerto TCP).
*   **Permisos seguros:** archivos `.remmina` y de contraseña VNC creados con modo 0600.

---

## Repositorio y Contacto

*   **Código fuente:** [https://github.com/jordilopezr/LCC](https://github.com/jordilopezr/LCC)
*   **Desarrollador:** Jordi Lopez Reyes
*   **Email:** [aim@jordilopezr.com](mailto:aim@jordilopezr.com)

## Apoya el Desarrollo

Si encuentras útil esta herramienta y quieres apoyar su desarrollo continuo, puedes hacerlo en [buymeacoffee.com/jordimlopezr](https://buymeacoffee.com/jordimlopezr).

---

## Requisitos del Sistema

1.  **Google Cloud SDK (`gcloud`):** instalado y en el PATH.
2.  **Cliente RDP** (al menos uno, para conexiones RDP):
    - **Remmina** (recomendado) — nativo o Flatpak
    - **FreeRDP** (`xfreerdp`) — basado en CLI, ampliamente disponible
    - **KRDC** — cliente predeterminado de KDE
    - **GNOME Connections** — cliente moderno de GNOME
3.  **Cliente VNC** (al menos uno, para conexiones VNC):
    - **Remmina** (recomendado) — soporta VNC y RDP
    - **TigerVNC** (`vncviewer`) — cliente ligero y rápido
    - **KRDC** — cliente KDE con soporte VNC/RDP
    - **Vinagre** — cliente GNOME clásico para VNC
4.  **Librerías del sistema (Linux):** `libsecret-1-dev`, `libjsoncpp-dev` (para almacenamiento seguro).
5.  **SSH keys configuradas:** para autenticación SFTP (ver sección de configuración SSH).
6.  **Application Default Credentials:** para usar Client Libraries (opcional, requiere `gcloud auth application-default login`).

## Compilación e Instalación

### 1. Clonar
```bash
git clone https://github.com/jordilopezr/LCC.git
cd LCC
```

### 2. Preparar entorno
```bash
# Opción A: script automatizado (Debian/Ubuntu/Fedora)
scripts/setup_environment.sh

# Opción B: manual (Debian/Ubuntu)
sudo apt-get install libsecret-1-dev libjsoncpp-dev
flutter pub get
cargo install flutter_rust_bridge_codegen
```

### 3. Generar bridge
```bash
flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root native --dart-output lib/src/bridge/api.dart
```

### 4. Ejecutar
```bash
# Linux
flutter run -d linux

# macOS (próximamente)
flutter run -d macos
```

> **Windows:** LCC no soporta Windows como plataforma anfitriona y no está previsto que lo haga.
> Para conectarte a VMs de GCP vía IAP desde Windows, recomendamos
> [IAP Desktop](https://github.com/GoogleCloudPlatform/iap-desktop) de Google Cloud.
> (LCC sí gestiona **VMs Windows** como destino: RDP y auto-credenciales.)

### 5. (Opcional) Habilitar Client Libraries
```bash
# Configurar Application Default Credentials
gcloud auth application-default login
# Dentro de la app, usa el toggle en el AppBar para cambiar entre CLI y Client Libraries
```

### 6. Configurar SSH para SFTP
```bash
# Generar clave SSH (si no tienes una)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# Agregar clave al ssh-agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Agregar clave pública a metadatos de GCP
gcloud compute project-info add-metadata \
  --metadata-from-file ssh-keys=<(echo "$(whoami):$(cat ~/.ssh/id_ed25519.pub)")
```

**Nota:** las claves SSH se propagan automáticamente a todas las instancias del proyecto. Puede tardar 1–2 minutos en instancias nuevas.

## Empaquetado

Los scripts de empaquetado están en `scripts/`; los artefactos se generan en `build_output/`:

```bash
scripts/package_deb.sh            # Paquete .deb (Debian/Ubuntu)
scripts/package_rpm.sh            # Paquete .rpm (Fedora/RHEL)
scripts/package_appimage.sh       # AppImage
scripts/package_tarball.sh        # Tarball genérico
scripts/build_all_containers.sh   # Builds reproducibles en contenedores podman (Ubuntu + AlmaLinux)
```

También hay un `PKGBUILD` para Arch Linux en `packaging/arch/`.

## Comparativa de Rendimiento

| Operación | gcloud CLI | Client Libraries | Mejora |
|-----------|------------|------------------|--------|
| List Projects | ~200 ms | ~150 ms | 1.3x más rápido |
| List Instances | ~300 ms | ~220 ms | 1.4x más rápido |
| Start/Stop/Reset | ~2–5 s | ~1.5–4 s | 1.2x más rápido |

*Benchmarks medidos en un sistema con conexión estable y autenticación previa.*

## Roadmap

### Próximo
- [ ] Soporte macOS (Intel/Apple Silicon)
- [ ] Caching de recursos (proyectos e instancias, TTL 5 min)
- [ ] Navegador de Google Cloud Storage (GCS)
- [ ] Integración con Secret Manager (solo lectura)
- [ ] Dashboard de Cloud Monitoring API
- [ ] i18n restante: mapeo de errores de Rust y notificaciones de escritorio (hoy en inglés)

### Incluido en 26H2
- [x] Rebrand a **Lightweight Cloud Connector** — arquitectura preparada para Linux y macOS
- [x] Aplicación 100% gratuita y open source: eliminado el modelo de licencias Free/Pro
- [x] VM Snapshot Manager
- [x] OS Login, VM Labels, Suspend/Resume
- [x] Tunnel Manager y Auto-Reconnect
- [x] Multi-Account Management
- [x] Connectivity Doctor (10 checks, auto-fix, export report)
- [x] SSHFS Mount Support
- [x] Windows Auto-Credentials
- [x] SQL Clients Integration (6 clientes)
- [x] Serial Console, VM Diagnostics, Audit Logs
- [x] VNC y RDP multi-cliente con fallback automático
- [x] Notificaciones desktop y Settings
- [x] Google Cloud Client Libraries, VM Lifecycle y auto-refresh
- [x] SFTP File Browser
- [x] Multi-tunnel y port forwarding
- [x] Builds en contenedores podman y scripts de empaquetado (deb, rpm, AppImage, tarball, Arch)
- [x] Soporte multi-idioma (i18n): interfaz completa en español e inglés

## Changelog

### 26H2 — build 20260715.1 — Release actual

**Rebrand: Lightweight Cloud Connector**
- Renombrado de "Linux Cloud Connector" a "Lightweight Cloud Connector" (LCC)
- Arquitectura preparada para Linux y macOS
- Nueva identidad visual con icono de app multiplataforma

**Modelo de distribución**
- LCC pasa a ser 100% gratuito y open source: eliminado por completo el modelo de licencias Free/Pro

**VM Snapshot Manager**
- Lista, crea y elimina snapshots de VM
- Backend Rust para operaciones CRUD vía GCP REST API

**OS Login, VM Labels y Suspend/Resume**
- Soporte OS Login para autenticación en instancias
- Visualización y filtrado por VM Labels
- Acción Suspend/Resume de VMs

**Tunnel Manager y Auto-Reconnect**
- Panel centralizado de gestión de túneles
- Auto-reconnect: reconexión automática de túneles caídos

**Multi-Account Management**
- Soporte para múltiples cuentas GCP simultáneas
- Cambio de cuenta sin reiniciar la aplicación

**Connectivity Doctor**
- 10 checks de diagnóstico en 5 categorías (Auth, Permisos, IAP, VM, Local)
- Auto-fix y exportación de reporte Markdown con datos redactados

**RDP y VNC multi-cliente**
- RDP: Remmina, FreeRDP, KRDC, GNOME Connections — fallback automático
- VNC: Remmina, TigerVNC, KRDC, Vinagre — fallback automático

**Empaquetado y distribución**
- Scripts consolidados en `scripts/` (deb, rpm, AppImage, tarball)
- Builds reproducibles en contenedores podman (Ubuntu y AlmaLinux)
- Compatibilidad con Fedora y PKGBUILD para Arch Linux

**Funcionalidades base**
- SFTP File Browser: upload/download/delete vía túnel SSH IAP
- Multi-tunnel y port forwarding universal (PostgreSQL, MySQL, HTTP, Redis, etc.)
- Notificaciones desktop para eventos de VMs y túneles
- Settings: tema, intervalo de refresh, cliente RDP/VNC preferido
- Dual API: gcloud CLI o Google Cloud Client Libraries (REST)
- VM lifecycle: start / stop / reset / suspend / resume
- SSHFS Mount, SQL Clients, Windows Auto-Credentials, Serial Console

---
© 2026 Jordi Lopez Reyes. Distribuido bajo licencia MIT.
