# Lightweight Cloud Connector (LCC)

🇪🇸 [Leer en español](README.es.md)

**Lightweight Cloud Connector** is a native, cross-platform desktop application designed to simplify and secure connections to Google Cloud Platform (GCP) instances via **Identity-Aware Proxy (IAP)**.

Built by **Jordi Lopez Reyes** with **Flutter** and **Rust** for optimal performance and security. LCC is **100% free and open source** (MIT license), with all features available without restrictions.

![Release](https://img.shields.io/badge/Release-26H2-brightgreen)
![Build](https://img.shields.io/badge/Build-20260731.1-blue)
![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20(coming%20soon)-blue)
![License](https://img.shields.io/badge/License-MIT-purple)

<img width="1332" height="819" alt="LCC main panel" src="https://github.com/user-attachments/assets/76d627da-e9a8-45c5-ab79-965b6dd3440c" />
<img width="1332" height="819" alt="Tunnel management in LCC" src="https://github.com/user-attachments/assets/9c2cb83f-d770-47b4-b0d5-be40897a2012" />

## Features

### VM Snapshot Manager
*   **List snapshots:** view all project snapshots with name, status, disk size, and storage.
*   **Create snapshot:** create snapshots of any VM disk with a custom name.
*   **Delete snapshot:** remove individual snapshots with confirmation.
*   **Size info:** displays `diskSizeGb` and `storageBytes` in human-readable format (GB/MB).
*   **Rust backend:** snapshot CRUD operations implemented natively in Rust via the GCP REST API.

### Multi-Account Management
*   **Multiple GCP accounts:** manage several Google Cloud accounts from a single interface.
*   **Quick switching:** switch between accounts without leaving the application.
*   **Independent authentication:** each account keeps its own credentials.
*   **Account list:** clear view of all configured accounts with authentication status.

### Tunnel Manager and Auto-Reconnect
*   **Consolidated view:** centralized panel with all active tunnels across all VMs.
*   **Native tunnel:** IAP tunnels are established natively in Rust, without launching the `gcloud` binary, with automatic fallback to the `gcloud` engine if the native path fails.
*   **Auto-reconnect:** automatically reconnects dropped tunnels without manual intervention.
*   **Individual management:** disconnect, reconnect, or inspect each tunnel separately.
*   **Health monitoring:** real-time health status (process + TCP port) every 30 seconds.
*   **Drop alerts:** immediate notifications when a tunnel drops unexpectedly.

### OS Login, VM Labels, and Suspend/Resume
*   **OS Login:** support for OS Login authentication instead of metadata SSH keys.
*   **VM Labels:** view and filter instances by GCP labels.
*   **Suspend/Resume:** suspend and resume VMs (in addition to start/stop/reset).

### Connectivity Doctor
*   **10 automatic checks:** diagnoses connectivity issues grouped into 5 categories.
*   **Authentication:** verifies gcloud CLI, active account, and ADC credentials.
*   **Project & Permissions:** verifies project access and enabled APIs (Compute, IAP).
*   **IAP & Network:** verifies the IAP API and firewall rules for `35.235.240.0/20`.
*   **VM Status:** verifies VM status and guest agent.
*   **Local Environment:** detects installed remote clients (SSH, RDP, VNC).
*   **Fix suggestions:** suggestions with copyable commands to resolve each issue.
*   **Auto-fix:** automatic actions such as re-authentication or starting a VM (with confirmation).
*   **Export report:** generates a Markdown report with sensitive data automatically redacted.
*   **Re-run:** re-runs the checks after applying fixes.

### Multi-Client RDP Support
*   **4 supported clients:** Remmina, FreeRDP (xfreerdp), KRDC, GNOME Connections.
*   **Automatic fallback:** if the preferred client isn't available, others are tried automatically.
*   **Persistent configuration:** select your favorite RDP client in Settings.
*   **Automatic detection:** identifies which clients are installed on the system.
*   **Full feature support:** fullscreen, custom resolution, credentials, ignore certificates.
*   **Remmina config files:** support for `.remmina` files with secure permissions (0600).

### Multi-Client VNC Support
*   **4 supported clients:** Remmina, TigerVNC (vncviewer), KRDC, Vinagre.
*   **Automatic fallback:** smart fallback if the preferred client isn't available.
*   **Flexible configuration:** quality (High/Medium/Low/Auto), fullscreen, view-only, custom resolution.
*   **Automatic detection:** identifies which VNC clients are installed (native + Flatpak).
*   **Secure config files:** password files with 0600 permissions and automatic cleanup.
*   **Port management:** automatic conversion between display number (:0, :1) and port (5900, 5901).

### SFTP File Transfer Browser
*   **File browser:** full graphical interface to explore remote files via SFTP.
*   **Upload:** upload local files to the remote instance with visual progress.
*   **Download:** download files from the instance to the local machine.
*   **Directory management:** create folders and delete remote files or directories.
*   **Secure transfer:** SFTP connections over IAP SSH tunnels (port 22).
*   **Auto-tunnel:** automatically creates the SSH tunnel if it doesn't exist when opening the browser.
*   **Size formatting:** automatic formatting (B, KB, MB, GB).

### Generic Port Forwarding and Multi-Tunnel
*   **Universal support:** connect to any TCP service via IAP (PostgreSQL, MySQL, HTTP, Redis, MongoDB, etc.).
*   **Simultaneous tunnels:** multiple tunnels per VM.
*   **Custom tunnel dialog:** 8 presets for common services plus custom port entry.
*   **Individual management:** disconnect specific tunnels without affecting the others.

### Desktop Notifications
*   **Native notifications** for important events.
*   **VM status changes:** automatic alerts when VMs switch between RUNNING and STOPPED.
*   **IAP tunnel alerts:** immediate notification when a tunnel drops unexpectedly.
*   **Lifecycle operations:** success or failure notifications for start/stop/reset.

### Customizable Configuration
*   **Settings dialog:** complete, organized configuration panel.
*   **Auto-refresh intervals:** 10s, 30s, 60s, 120s, 300s, or custom 5–600s.
*   **Theme:** Light / Dark / System.
*   **Language:** Spanish and English. Follows the system language by default; can be forced from Settings and applies instantly, without restarting.
*   **Persistence:** all settings are saved between sessions.

### Multi-language Support (i18n)
*   **Spanish and English:** fully translated interface (~666 keys, verified parity between both languages).
*   **Automatic detection:** uses the operating system's language by default.
*   **Hot swap:** the Settings selector applies the language without restarting the application.
*   **Standard base:** Flutter's `gen-l10n` with `.arb` dictionaries, making it easy to add more languages.
*   **Note:** IAP tunnel errors use typed codes and are translated (EN/ES). Other error messages generated in Rust (`doctor`, `sftp`, `snapshots`, `gcloud`) and desktop notifications remain in English (pending for a future release).

### Google Cloud Client Libraries Integration
*   **Dual API:** switch between gcloud CLI and Google Cloud Client Libraries (REST API).
*   **Performance:** Client Libraries are 1.3–1.5x faster than the CLI.
*   **Hot swap:** toggle in the AppBar to switch between methods in real time.

### VM Lifecycle Management
*   **Start / Stop / Reset / Suspend / Resume.**
*   **Status indicators:** buttons enabled or disabled based on the VM's current state.

### Observability and Monitoring
*   **Structured logging:** persistent system with automatic rotation (10 MB, 5 files).
*   **Export logs:** UI button to export consolidated logs.
*   **Metrics dashboard:** uptime, last check, and real-time health status.

### Security and Reliability
*   **Input validation:** protection against command injection via regex validation.
*   **Timeouts:** all gcloud commands have a 10 s timeout.
*   **Health monitoring:** automatic tunnel verification every 30 seconds (process + TCP port).
*   **Secure permissions:** `.remmina` and VNC password files created with mode 0600.

---

## Repository and Contact

*   **Source code:** [https://github.com/jordilopezr/LCC](https://github.com/jordilopezr/LCC)
*   **Developer:** Jordi Lopez Reyes
*   **Email:** [aim@jordilopezr.com](mailto:aim@jordilopezr.com)

## Support the Project

If you find this tool useful and want to support its ongoing development, you can do so at [buymeacoffee.com/jordimlopezr](https://buymeacoffee.com/jordimlopezr).

---

## System Requirements

1.  **Google Cloud SDK (`gcloud`):** installed and on the PATH.
2.  **RDP client** (at least one, for RDP connections):
    - **Remmina** (recommended) — native or Flatpak
    - **FreeRDP** (`xfreerdp`) — CLI-based, widely available
    - **KRDC** — KDE's default client
    - **GNOME Connections** — modern GNOME client
3.  **VNC client** (at least one, for VNC connections):
    - **Remmina** (recommended) — supports VNC and RDP
    - **TigerVNC** (`vncviewer`) — lightweight, fast client
    - **KRDC** — KDE client with VNC/RDP support
    - **Vinagre** — classic GNOME client for VNC
4.  **System libraries (Linux):** `libsecret-1-dev`, `libjsoncpp-dev` (for secure storage).
5.  **SSH keys configured:** for SFTP authentication (see SSH setup section).
6.  **Application Default Credentials:** to use Client Libraries (optional, requires `gcloud auth application-default login`).

## Building and Installation

### 1. Clone
```bash
git clone https://github.com/jordilopezr/LCC.git
cd LCC
```

### 2. Prepare environment
```bash
# Option A: automated script (Debian/Ubuntu/Fedora)
scripts/setup_environment.sh

# Option B: manual (Debian/Ubuntu)
sudo apt-get install libsecret-1-dev libjsoncpp-dev
flutter pub get
cargo install flutter_rust_bridge_codegen
```

### 3. Generate bridge
```bash
flutter_rust_bridge_codegen generate --rust-input crate::api --rust-root native --dart-output lib/src/bridge/api.dart
```

### 4. Run
```bash
# Linux
flutter run -d linux

# macOS (coming soon)
flutter run -d macos
```

> **Windows:** LCC does not support Windows as a host platform, and there are no plans to add it.
> To connect to GCP VMs via IAP from Windows, we recommend
> [IAP Desktop](https://github.com/GoogleCloudPlatform/iap-desktop) by Google Cloud.
> (LCC does manage **Windows VMs** as targets: RDP and auto-credentials.)

### 5. (Optional) Enable Client Libraries
```bash
# Configure Application Default Credentials
gcloud auth application-default login
# Inside the app, use the AppBar toggle to switch between CLI and Client Libraries
```

### 6. Configure SSH for SFTP
```bash
# Generate an SSH key (if you don't have one)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# Add the key to ssh-agent
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Add the public key to GCP project metadata
gcloud compute project-info add-metadata \
  --metadata-from-file ssh-keys=<(echo "$(whoami):$(cat ~/.ssh/id_ed25519.pub)")
```

**Note:** SSH keys are automatically propagated to all project instances. It may take 1–2 minutes on new instances.

## Packaging

Packaging scripts live in `scripts/`; artifacts are generated in `build_output/`:

```bash
scripts/package_deb.sh            # .deb package (Debian/Ubuntu)
scripts/package_rpm.sh            # .rpm package (Fedora/RHEL)
scripts/package_appimage.sh       # AppImage
scripts/package_tarball.sh        # Generic tarball
scripts/build_all_containers.sh   # Reproducible builds in podman containers (Ubuntu + AlmaLinux)
```

There's also a `PKGBUILD` for Arch Linux in `packaging/arch/`.

## Performance Comparison

| Operation | gcloud CLI | Client Libraries | Improvement |
|-----------|------------|------------------|-------------|
| List Projects | ~200 ms | ~150 ms | 1.3x faster |
| List Instances | ~300 ms | ~220 ms | 1.4x faster |
| Start/Stop/Reset | ~2–5 s | ~1.5–4 s | 1.2x faster |

*Benchmarks measured on a system with a stable connection and prior authentication.*

## Roadmap

### Next
- [ ] macOS support (Intel/Apple Silicon)
- [ ] Google Cloud Storage (GCS) browser
- [ ] Secret Manager integration (read-only)
- [ ] Cloud Monitoring API dashboard
- [ ] Remaining i18n: Rust error mapping and desktop notifications (currently English only)

### Coming next (in branches)
_Developed and reviewed, not yet merged into a published release:_
- [ ] Security hardening: resolve `gcloud` to a validated absolute path (anti PATH-hijack); stop persisting VNC passwords to disk; idle IAP-tunnel reaper; `SECURITY.md` + threat model
- [ ] Tabbed workspace: tabs that survive sidebar changes, embedded SSH terminal, SFTP panel, and a browser-style tab strip (overflow, pinned tabs, groups, drag reorder)
- [ ] SFTP dual-pane browser (WinSCP-style) with a cancelable transfer queue
- [ ] Parallel SFTP transfers
- [ ] Native Rust IAP tunnel engine (opt-in)

### Included in 26H2 Update 1 (build 20260731.1)
- [x] Signed releases with an SBOM and build provenance (keyless Sigstore attestations) via GitHub Actions
- [x] Cross-distro packaging: installs and runs on modern Fedora and Debian (OpenSSL 3 build bases, declared runtime dependencies)
- [x] In-app re-login: detects an expired GCP session and offers a one-tap re-authenticate banner

### Included in 26H2
- [x] Rebrand to **Lightweight Cloud Connector** — architecture ready for Linux and macOS
- [x] 100% free and open source app: removed the Free/Pro license model
- [x] VM Snapshot Manager
- [x] OS Login, VM Labels, Suspend/Resume
- [x] Tunnel Manager and Auto-Reconnect
- [x] Multi-Account Management
- [x] Connectivity Doctor (10 checks, auto-fix, export report)
- [x] SSHFS Mount Support
- [x] Windows Auto-Credentials
- [x] SQL Clients Integration (6 clients)
- [x] Serial Console, VM Diagnostics, Audit Logs
- [x] Multi-client VNC and RDP with automatic fallback
- [x] Desktop notifications and Settings
- [x] Google Cloud Client Libraries, VM Lifecycle, and auto-refresh
- [x] SFTP File Browser
- [x] Multi-tunnel and port forwarding
- [x] Podman container builds and packaging scripts (deb, rpm, AppImage, tarball, Arch)
- [x] Multi-language support (i18n): full interface in Spanish and English

## Changelog

### 26H2 Update 1 — build 20260731.1 — Current release

**Signed releases + SBOM (supply-chain integrity)**
- A tag-triggered GitHub Actions workflow builds the Linux artifacts (deb, rpm, AppImage, tarball) and attaches keyless build-provenance and an SPDX SBOM attestation plus SHA256 checksums, published as a draft GitHub Release
- Verify a download with `gh attestation verify` (see `docs/RELEASES.md`)

**Packaging & distribution**
- CI-built packages now launch: fixed an app-startup crash where the packaged Dart/Rust bridge went out of sync (a content-hash mismatch) — the committed bridge is now built as-is instead of regenerated at package time
- Packages build on OpenSSL 3 bases (ubuntu:22.04 / almalinux:9) and declare their runtime dependencies (e.g. `libsecret`), so the app installs and runs on modern Fedora and Debian instead of failing to load a library
- The `.deb` now ships a `postinst` that refreshes the desktop and icon databases, so the menu entry registers correctly on install

**In-app GCP re-login**
- When the gcloud/ADC session expires and project/instance listing fails, a non-modal banner offers a one-tap "Re-authenticate" that reuses `gcloud auth login` and refreshes the list on success
- Also covers accounts authenticated only via `gcloud auth login` (no ADC configured), which previously surfaced an unrecognized error

**Version display**
- The public edition/update/build is centralized in a single source (`lib/src/version.dart`) and shown as "Edition 26H2 · Update 1 · Build 20260731.1"

### 26H2 — build 20260715.1

**Rebrand: Lightweight Cloud Connector**
- Renamed from "Linux Cloud Connector" to "Lightweight Cloud Connector" (LCC)
- Architecture ready for Linux and macOS
- New visual identity with a cross-platform app icon

**Distribution model**
- LCC becomes 100% free and open source: the Free/Pro license model has been completely removed

**VM Snapshot Manager**
- List, create, and delete VM snapshots
- Rust backend for CRUD operations via the GCP REST API

**OS Login, VM Labels, and Suspend/Resume**
- OS Login support for instance authentication
- View and filter by VM Labels
- Suspend/Resume VM action

**Tunnel Manager and Auto-Reconnect**
- Centralized tunnel management panel
- Auto-reconnect: automatic reconnection of dropped tunnels

**Multi-Account Management**
- Support for multiple simultaneous GCP accounts
- Switch accounts without restarting the application

**Connectivity Doctor**
- 10 diagnostic checks across 5 categories (Auth, Permissions, IAP, VM, Local)
- Auto-fix and Markdown report export with redacted sensitive data

**Multi-client RDP and VNC**
- RDP: Remmina, FreeRDP, KRDC, GNOME Connections — automatic fallback
- VNC: Remmina, TigerVNC, KRDC, Vinagre — automatic fallback

**Packaging and distribution**
- Scripts consolidated in `scripts/` (deb, rpm, AppImage, tarball)
- Reproducible builds in podman containers (Ubuntu and AlmaLinux)
- Fedora compatibility and PKGBUILD for Arch Linux

**Core functionality**
- SFTP File Browser: upload/download/delete over IAP SSH tunnel
- Multi-tunnel and universal port forwarding (PostgreSQL, MySQL, HTTP, Redis, etc.)
- Desktop notifications for VM and tunnel events
- Settings: theme, refresh interval, preferred RDP/VNC client
- Dual API: gcloud CLI or Google Cloud Client Libraries (REST)
- VM lifecycle: start / stop / reset / suspend / resume
- SSHFS Mount, SQL Clients, Windows Auto-Credentials, Serial Console

---
© 2026 Jordi Lopez Reyes. Distributed under the MIT license.
