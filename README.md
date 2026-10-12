# Lightweight Cloud Connector (LCC)

🇪🇸 [Leer en español](README.es.md)

**Lightweight Cloud Connector** is a native, cross-platform desktop application designed to simplify and secure connections to Google Cloud Platform (GCP) instances via **Identity-Aware Proxy (IAP)**.

Built by **Jordi Lopez Reyes** with **Flutter** and **Rust** for optimal performance and security. LCC is **100% free and open source** (GPLv3 or later), with all features available without restrictions.

![Release](https://img.shields.io/badge/Release-26H2-brightgreen)
![Build](https://img.shields.io/badge/Build-20260731.1-blue)
![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20(coming%20soon)-blue)
![License](https://img.shields.io/badge/License-GPLv3%2B-purple)
![Preview](https://img.shields.io/badge/Preview-27H1%20build%2020261012.50-orange)

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
*   **Native tunnel:** IAP tunnels are established natively in Rust, without launching the `gcloud` binary. There is **no silent fallback**: if the native path fails, the tunnel reports the error instead of quietly switching engines. The `gcloud` engine stays available as an explicit choice in Settings → Advanced (or via `LCC_TUNNEL_ENGINE`).
*   **Auto-reconnect:** automatically reconnects dropped tunnels without manual intervention.
*   **Individual management:** disconnect, reconnect, or inspect each tunnel separately.
*   **Health monitoring:** real-time health status (process + TCP port) every 30 seconds.
*   **Drop alerts:** immediate notifications when a tunnel drops unexpectedly.

### OS Login, VM Labels, and Suspend/Resume
*   **OS Login:** support for OS Login authentication instead of metadata SSH keys.
*   **VM Labels:** view and filter instances by GCP labels.
*   **Suspend/Resume:** suspend and resume VMs (in addition to start/stop/reset).

### Connectivity Doctor
*   **13 automatic checks:** diagnoses connectivity issues grouped into 5 categories.
*   **Authentication:** three native rows — *LCC Credential Store* (the system keyring answers), *LCC Account Index* (every listed account still has its stored sign-in) and *LCC Session* (LCC can mint an access token right now) — plus three gcloud rows (*gcloud CLI Installed*, *gcloud Account Active*, *Application Default Credentials*). Each set reports `Skipped` when the other engine is selected, so the report never fails you for a tool you are not using.
*   **Project & Permissions:** verifies project access and enabled APIs (Compute, IAP).
*   **IAP & Network:** verifies the IAP API and firewall rules for `35.235.240.0/20`.
*   **VM Status:** verifies VM status and guest agent.
*   **Local Environment:** detects installed remote clients (SSH, RDP, VNC).
*   **Fix suggestions:** copyable commands for each issue, and — for the remedies that would otherwise need `gcloud` (enable the Compute Engine or IAP API, add the IAP firewall rule, start a stopped VM) — a Cloud Console link alongside the command.
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

### Google Cloud APIs (native REST client)
*   **One path, no toggle:** projects, instances, snapshots and lifecycle actions all go through LCC's own Rust REST client against the Google Cloud APIs. The old "Dual API" AppBar toggle between the gcloud CLI and the Client Libraries no longer exists — there is no CLI path left to switch to.
*   **No subprocess per call:** each operation is a single HTTPS request from the Rust client, instead of spawning a `gcloud` process and parsing its output.
*   **Access tokens:** minted from LCC's own stored session under the native sign-in engine; read from gcloud (`gcloud auth print-access-token`, falling back to ADC) under the gcloud engine.

### VM Lifecycle Management
*   **Start / Stop / Reset / Suspend / Resume.**
*   **Status indicators:** buttons enabled or disabled based on the VM's current state.

### Observability and Monitoring
*   **Structured logging:** persistent system with automatic rotation (10 MB, 5 files).
*   **Export logs:** UI button to export consolidated logs.
*   **Metrics dashboard:** uptime, last check, and real-time health status.

### Security and Reliability
*   **Input validation:** protection against command injection via regex validation.
*   **Timeouts:** every gcloud command runs under one — 10–30 s for queries, 120 s for VM lifecycle operations (start, stop, reset, suspend, resume).
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

1.  **RDP client** (at least one, for RDP connections):
    - **Remmina** (recommended) — native or Flatpak
    - **FreeRDP** (`xfreerdp`) — CLI-based, widely available
    - **KRDC** — KDE's default client
    - **GNOME Connections** — modern GNOME client
2.  **VNC client** (at least one, for VNC connections):
    - **Remmina** (recommended) — supports VNC and RDP
    - **TigerVNC** (`vncviewer`) — lightweight, fast client
    - **KRDC** — KDE client with VNC/RDP support
    - **Vinagre** — classic GNOME client for VNC
3.  **System libraries (Linux):** `libsecret-1-dev`, `libjsoncpp-dev` (for secure storage).
4.  **A running Secret Service** (GNOME Keyring, KWallet, or equivalent): LCC keeps each account's sign-in in the OS keyring. Doctor's *LCC Credential Store* row tells you when it is not reachable.
5.  **A Google account** with access to the GCP projects you want to manage.

### Optional

*   **Google Cloud SDK (`gcloud`) — optional.** LCC signs in on its own and opens IAP tunnels on its own; neither path uses gcloud, so you do not need it installed. It is still worth having for two things:
    - it is the **alternative sign-in engine**, selectable in Settings under *Sign-in method*. On that engine LCC reads the session gcloud already has — you keep that session yourself with `gcloud auth login`;
    - it is how you run the **administration commands Doctor suggests**: enabling the Compute Engine and IAP APIs, adding the IAP firewall rule for `35.235.240.0/20`, starting a stopped VM. Doctor prints a Cloud Console link for each of those as well, so gcloud is a convenience there rather than a prerequisite.
*   **Your own SSH keys:** LCC generates and publishes its own key when a VM needs one (asking first), and also offers any key already in `~/.ssh`. Bring your own only if you would rather it used that.

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

### 5. Sign in

Start LCC and add an account from the accounts dialog. LCC opens your browser for
the Google sign-in (OAuth 2.0 authorization code with PKCE over a loopback
redirect) and stores the resulting refresh token in the system keyring. There is
no terminal step: `gcloud auth application-default login` is not needed.

To use gcloud's session instead, open **Settings → Sign-in method** and pick
*Use the gcloud CLI*. On that engine LCC never signs you in or out — it reads
gcloud's credentials and tells you which command to run (`gcloud auth login`,
`gcloud auth revoke <account>`) when an auth action is needed.

Three engines are selectable, each with an environment variable that overrides
the stored choice (Settings says so when one is set):

| Engine | Where | Environment variable |
|---|---|---|
| Sign-in | Settings → Sign-in method | `LCC_AUTH_ENGINE` |
| IAP tunnel | Settings → Advanced | `LCC_TUNNEL_ENGINE` |
| SSH port forward | Settings → Advanced | `LCC_SSH_FORWARD_ENGINE` |

All three accept `native` or `gcloud`, and all three default to `native`.

### 6. (Optional) Configure SSH for SFTP yourself

LCC handles this on its own: the first time it needs SSH access to a VM it asks
for permission and then publishes its own key
(`~/.local/share/lightweight_cloud_connector/ssh/lcc_ed25519`) — through OS Login
when the instance has it enabled, otherwise **merged** into the instance's
`ssh-keys` metadata, never overwriting the other entries. Keys already in
`~/.ssh` are offered too.

If you would rather publish a key yourself, the manual route still works:

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

## Roadmap

### Next
- [ ] macOS support (Intel/Apple Silicon)
- [ ] Google Cloud Storage (GCS) browser
- [ ] Secret Manager integration (read-only)
- [ ] Cloud Monitoring API dashboard
- [ ] Finish the 27H1 Preview manual QA (see *Known gaps* below) before a stable 27H1
- [ ] SSH host key verification for the native SSH client

### Included in 27H1 Preview (build 20261012.50)
- [x] Native Rust IAP tunnel engine, with automatic fallback to `gcloud`
- [x] Native authentication: own OAuth flow and token store, `gcloud auth` no longer invoked
- [x] Native SSH access: LCC's own key, published via instance metadata or OS Login
- [x] Tabbed workspace with an embedded SSH terminal and an SFTP tab
- [x] SFTP dual-pane browser with a cancelable transfer queue, and parallel transfers
- [x] Per-account workspace: projects, history and favorites belong to the active account
- [x] VNC on any display, remembered per VM
- [x] Remaining i18n: Rust error mapping and desktop notifications now localized (EN/ES)

### Still in branches
_Developed and reviewed, not yet merged into a published release:_
- [ ] Security hardening: resolve `gcloud` to a validated absolute path (anti PATH-hijack); stop persisting VNC passwords to disk; idle IAP-tunnel reaper

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

### 27H1 Preview — build 20261012.50 — Preview

**This is a preview release. Its manual QA is not finished — see *Known gaps*
at the end of this entry before running it on anything you care about.** The
latest stable release remains the current 26H2 line.

**Native IAP tunnel engine**
- The tunnel is a Rust WebSocket relay client instead of a `gcloud` subprocess: fewer moving parts, no CLI to find on `PATH`, and failures that can be reported instead of parsed out of stderr
- Automatic fallback to the `gcloud` engine, which is kept as an escape hatch and selectable in Settings
- Typed tunnel errors with stable codes, localized in English and Spanish; the tunnel manager names the engine holding each entry, and the one that failed on a row in error

**Native authentication**
- LCC performs its own OAuth flow and keeps the refresh token in the system keyring; `gcloud auth login` is no longer invoked
- Account list, switch, add and remove are served from LCC's own token store
- The auth engine is a visible choice in Settings, and the startup log states which engines are in force and where each came from
- The OAuth client secret is supplied at build time rather than committed. An installed app cannot keep a secret — PKCE is what protects the exchange — but a secret in a public repository is one that scanners find and providers revoke. A build without it has no native sign-in and falls back to the gcloud engine

**Native SSH access**
- LCC generates and stores its own ed25519 key and publishes it to the instance, merging the `ssh-keys` metadata blob rather than replacing it, or through OS Login
- Native port forwarding is the default; the SSH user is derived rather than guessed

**Tabbed workspace**
- Tabs that survive sidebar changes, an embedded SSH terminal (pty + xterm), and an SFTP tab
- Browser-style tab strip with overflow and auto-scroll to the active tab, and a confirmation when closing with live sessions

**SFTP**
- Dual-pane browser with a cancelable transfer queue
- Parallel ranged transfers over multiple SSH sessions, with global byte progress

**Per-account workspace**
- Selected projects, connection history and favorites belong to the active account. Switching accounts disconnects every tunnel, clears the previous account's view and restores the new account's
- Lists saved before accounts were separated are handed to the account signed in when the upgrade lands, and then removed so a second account does not inherit them

**VNC**
- The VM's display is a field in the connect dialog and is remembered per VM, so a server on `:1` (port 5901) is reachable. The port was hardcoded to 5900

**Diagnostics**
- Connectivity Doctor: a usable console path, remedies that do not require the tool you are missing, a real refresh, and a keyring liveness check
- The log states the running build and binary, the effective engines, and whether the app shut itself down

#### Known gaps

Carried into this preview deliberately, so they are not discovered by surprise:

- **Manual QA incomplete.** Three areas have no data yet: zombie processes after closing clients, whether disconnecting in LCC cuts a live RDP session, and the no-regression pass over RDP and SSH forwarding on both engines
- **No SSH host key verification.** The native SSH client does not check the host key. The session runs inside the IAP tunnel, which is authenticated TLS to Google, so the exposure is narrower than a raw SSH connection — but it is a real gap and it is tracked in the roadmap
- **Connectivity Doctor reports one failing check** and the log keeps only the summary, so which row fails is not yet known
- **With the `gcloud` tunnel engine**, `start-iap-tunnel` has been seen to fail with a missing `compute.instances.get` permission while the app reads the same VM successfully with the same account. Under investigation; it can make unrelated tests look broken
- **A native forward left idle** does not notice that it died until someone connects through it
- **The VNC launch-failure dialog** is covered by widget tests but has not been confirmed on screen by a human

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
© 2025-2026 Jordi Lopez Reyes. Distributed under the [GNU GPL v3 or later](LICENSE), with the additional terms in [NOTICE](NOTICE): the name "Lightweight Cloud Connector" and the LCC logo are not licensed for use in modified versions. Releases up to 26H2 Update 1 were published under the MIT license.
