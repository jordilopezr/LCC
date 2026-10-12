# LCC Threat Model

**Status:** living document · **Applies to:** Lightweight Cloud Connector (LCC),
the Flutter + Rust desktop client for Google Cloud VM access over Identity-Aware
Proxy (IAP).

This document states what LCC protects, the boundaries it trusts, the controls
that are actually implemented (with source references), and — importantly — the
**residual risks** we accept or are actively hardening. It is deliberately honest
about gaps: a threat model that only lists strengths is marketing, not security.

## 1. What LCC is

LCC is a single-user desktop application. It lists a user's GCP Compute
instances, opens IAP tunnels to them, and launches or embeds access sessions
(SSH, SFTP, RDP, VNC), plus operational features (snapshots, suspend/resume,
serial-console diagnostics, port forwarding). It runs as the invoking OS user. By default it
authenticates to Google itself (OAuth 2.0 authorization code + PKCE over a
loopback redirect, refresh token in the OS keyring — `native/src/oauth.rs`,
`native/src/token_store.rs`); selecting the `gcloud` auth engine instead makes it
read the user's existing `gcloud`/ADC credentials.

## 2. Assets

| Asset | Why it matters |
|---|---|
| GCP OAuth tokens (LCC's own refresh tokens in the OS keyring, or gcloud/ADC credentials on the gcloud engine) | Grant API + tunnel access to the user's projects |
| Live IAP tunnels (local loopback ports) | A connected tunnel is an authenticated path to a VM's port |
| VM session credentials (SSH keys, Windows/VNC passwords) | Direct host access |
| Temporary client config files (`.remmina`, VNC) | May contain a plaintext password on disk |
| Diagnostic exports (Doctor) | Could leak tokens/paths if not redacted |

## 3. Trust boundaries

1. **User ↔ LCC UI** — trusted; the local user is the principal.
2. **LCC ↔ `gcloud` subprocess** — only when a `gcloud` engine is selected. On
   the defaults (native auth, native tunnel, native SSH forward) no `gcloud`
   process is spawned at all.
3. **LCC ↔ local tunnel listener** — LCC opens a `127.0.0.1` TCP port that
   external clients (RDP/VNC/SSH) connect to.
4. **LCC ↔ external client processes** — `xfreerdp`, Remmina, VNC viewers, the
   system `ssh`, launched as child processes.
5. **LCC ↔ GCP APIs / IAP relay** — TLS to Google; IAP authorizes before the
   tunnel carries any traffic.
6. **LCC ↔ target VM** — over the tunnel; the VM's own SSHD/RDP/OS enforces
   authentication and authorization.

**Core assumption:** the local machine and the OS user account are trusted. An
adversary with code execution as the *same UID* can already read this user's
files, environment, and `/proc`. Several residual items below are hardened
anyway to raise the bar and to satisfy corporate review, but same-UID compromise
is largely outside the primary model.

## 4. Implemented controls (verified in source)

| Control | Where |
|---|---|
| **argv-only subprocess spawning; no `sh -c` anywhere** → structural anti–command-injection | all `Command::new(...).args(...)`; `grep 'sh -c'` is empty |
| **RDP password never on the command line** (client prompts) → anti CWE-214 | `native/src/rdp_client/freerdp.rs` |
| **Loopback-only, ephemeral tunnel port** | `native/src/tunnel.rs` (`TcpListener::bind("127.0.0.1:0")`) |
| **`0600` credential config files + immediate delete + stale-file sweep** | `native/src/rdp_client/utils.rs` (`from_mode(0o600)`, `remove_file`, `cleanup_old_config_files`) |
| **Sensitive-data redaction on diagnostic export** | `native/src/redact.rs` (`redact_sensitive`) |
| **Remote path-traversal rejection; local writes jailed to `$HOME`** | `native/src/sftp.rs` (`validate_and_normalize_path`, `validate_local_path`) |
| **Transfer size cap (DoS bound)** | `native/src/sftp.rs` (`MAX_FILE_SIZE`) |
| **Input validation** (usernames, project ids, etc.) as defense-in-depth | `native/src/validation.rs` |
| **VM auth delegated to Google IAP** (authorizes before the tunnel forwards) | IAP relay |

## 5. Threats, mitigations, and residual risk

### T1 — Same-UID process connects to the local tunnel listener  *(residual: bounded)*
The tunnel is a `127.0.0.1` TCP socket. TCP has **no per-process ACL**, so any
process running as the same UID can `connect()` to the port and reach the
authenticated VM path while the tunnel is open. On the `gcloud` engine
LCC does not even own the socket — `gcloud … --local-host-port=localhost:PORT`
binds it — so there it cannot substitute a Unix-domain socket or add a
per-connection token. On the default native engine LCC does own the listener,
so that option is open to it. Randomizing the loopback address/port is **not** a control here: a
same-UID attacker simply enumerates listeners via `ss` / `/proc/net/tcp`.
- *Current mitigations:* loopback interface only (not routable off-host);
  ephemeral random port; explicit teardown on disconnect; tunnel startup aborts
  and cleans up if the port never listens (`native/src/tunnel.rs`, `start_tunnel`).
- *Idle reaper:* a background thread closes any tunnel with **zero** ESTABLISHED
  loopback connections for more than 120s (`native/src/tunnel.rs`,
  `reap_idle_tunnels_once`). This bounds the window for tunnels whose client
  exited, never connected (failed launch), or was forgotten. A live session
  keeps its TCP connection ESTABLISHED, so it is never reaped. A UI attached to
  a tunnel but connectionless between actions (the SFTP browser, which opens a
  fresh `ssh2::Session` per operation) pins its tunnel with a periodic
  `touch_tunnel_by_local_port` call every 60s, so a browser left open is not
  reaped even between its stateless operations.
- *Residual:* a hostile same-UID process during the (now bounded) lifetime of a
  tunnel that is actually in use.
- *Out of scope / future:* real isolation via a private **network namespace**
  (the only control that stops a same-UID process reaching the port) is heavy,
  likely requires elevated setup, and is best coupled with the native Rust
  tunnel engine; it is deferred.

### T2 — Credentials visible in process arguments  *(mitigated)*
`/proc/PID/cmdline` and `ps` are readable by same-UID processes.
- *Mitigation:* the RDP path does **not** pass the password as an argument
  (`freerdp.rs`); VNC viewers receive no password argument; secrets that a client
  requires go through a file, not argv.

### T3 — Plaintext password persisted in a client config file  *(residual: partial)*
Remmina requires the password inside its `.remmina` file.
- *Current mitigations:* file created `0600`; deleted immediately after launch;
  a startup sweep removes stale files left by a crash/`SIGKILL`
  (`rdp_client/utils.rs`).
- *Residual:* between write and cleanup — and in the crash window before the next
  sweep — a `0600` plaintext password sits on disk (readable by same-UID/root).
- *Planned:* prefer prompting over writing the secret where the client allows,
  and tighten guaranteed cleanup (RAII); see `security/credential-files`.

### T4 — Command injection  *(mitigated)*
- *Mitigation:* all subprocesses use argv arrays; **no shell** is ever invoked,
  so shell metacharacters cannot be interpreted. Input validation is
  defense-in-depth, not the primary control.

### T5 — `PATH` hijacking of `gcloud`  *(residual: real, low-med)*
`gcloud` is no longer invoked by bare name: every call site resolves it through
`gcloud_bin::gcloud_path()` (`native/src/gcloud_bin.rs`), which walks a candidate
list — `~/google-cloud-sdk/bin`, then a fixed set of known SDK directories, then
**every `$PATH` entry** (`native/src/gcloud_bin.rs:58-70`) — and takes the first
candidate that canonicalizes to a regular file with an executable bit whose
parent directory is not world-writable. `$PATH` is therefore still a candidate
source, consulted after the known locations. On a machine where the SDK lives in
none of those known locations, a directory an attacker controls on `$PATH` can
still supply the binary that runs with the user's privileges, as long as it
passes those checks.
- *Residual:* **narrowed, not closed.** The checks reject the crude cases
  (missing, non-executable, world-writable parent); they do not establish that
  the executable is the genuine SDK, and they do not remove `$PATH` from the
  search.
- *Open — needs a security owner:* decide what "trusted enough" means for this
  binary (pin to a verified install location, check a signature, or drop the
  `$PATH` fallback altogether) and whether the remaining exposure is acceptable
  now that `gcloud` is off the default path entirely; see
  `security/gcloud-abs-path`.

### T6 — Path traversal on transfers  *(mitigated)*
- *Mitigation:* `..` components are rejected before normalization; local writes
  are constrained to `$HOME`; remote authorization is enforced by the VM's SSHD.

### T7 — Secret leakage through logs / diagnostic bundle  *(mitigated)*
- *Mitigation:* the Doctor export runs through `redact_sensitive`
  (tokens, passwords, API keys). Ongoing: keep the redaction patterns current.

### T8 — Supply chain / release integrity  *(residual: not yet addressed)*
No signed releases or SBOM today.
- *Planned:* signed release artifacts + SBOM in CI; see `ci/signed-releases-sbom`.

### T9 — Denial of service via large transfers  *(mitigated)*
- *Mitigation:* `MAX_FILE_SIZE` bounds a single transfer.

## 6. Security advantage vs. subprocess reduction

The native Rust IAP tunnel removes the `gcloud`/Python subprocess (and its
transitive dependency surface) from the critical connection path. That is a
genuine attack-surface reduction, and it is now the **default**
(`native/src/tunnel.rs`, `tunnel_engine`); the `gcloud` engine is an explicit
opt-out. The same is true of authentication and of SSH port forwarding, so a
default install spawns no `gcloud` process on any connection path.

## 7. Out of scope (current)

- Malicious code already executing as the same UID (see the core assumption).
- OS/kernel, `gcloud` SDK internals, and the security of the external
  RDP/VNC/SSH clients themselves.
- Multi-user / shared-host hardening beyond file permissions.
- Enterprise access governance (device trust / BeyondCorp context) — under
  evaluation, not implemented.

## 8. Planned hardening (tracked, one branch each)

| Item | Branch | Effort |
|---|---|---|
| Resolve `gcloud` to a validated absolute path | `security/gcloud-abs-path` | Low–med |
| Prompt over writing secrets + guaranteed credential-file cleanup | `security/credential-files` | Med |
| Isolate/authenticate the local tunnel listener (design first) | `security/loopback-listener` | Med–high |
| Signed releases + SBOM in CI | `ci/signed-releases-sbom` | Med |
| Evaluate device-certificate / BeyondCorp support | (evaluation) | TBD |

This document should be updated as each item lands.
