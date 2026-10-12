# Security Policy

Lightweight Cloud Connector (LCC) is a desktop tool for privileged access to
Google Cloud VMs over Identity-Aware Proxy (IAP). We take its security posture
seriously and welcome coordinated disclosure.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through **GitHub's private vulnerability reporting** on this
repository: open the **Security** tab → **Report a vulnerability**. This opens a
private advisory visible only to the maintainers.

If private reporting is unavailable to you, contact the maintainer directly and
ask for a secure channel before sending any details. *(Maintainers: add a
dedicated security contact address here if you prefer email over GitHub
advisories.)*

When reporting, please include:

- affected version / commit and platform (Linux distro, etc.),
- a description of the issue and its impact,
- reproduction steps or a proof of concept,
- any suggested remediation.

We aim to acknowledge a report within **5 business days** and to agree on a
disclosure timeline with the reporter. Please give us reasonable time to release
a fix before any public disclosure.

## Supported versions

LCC is pre-1.0 and ships from a rolling release line. Security fixes land on the
current release branch; there is no long-term-support back-port guarantee yet.
Run the latest release.

## Security posture (summary)

LCC's design already applies several concrete controls. These are verified in
the source, not aspirational:

- **No shell interpolation.** Every external process is spawned with an argv
  array via `std::process::Command` / `tokio::process::Command`; there is no
  `sh -c` / shell string anywhere in the codebase. Argument arrays are a
  structural guarantee against command injection — not a denylist.
- **No credentials in process arguments.** The RDP client deliberately does not
  pass the password on the command line (which would be visible via `ps` and
  `/proc/PID/cmdline` to same-UID processes); it lets the client prompt instead — a control against CWE-214 (Invocation
  with Visible Sensitive Information) (`native/src/rdp_client/freerdp.rs`).
- **Loopback-only tunnels.** The native IAP tunnel listener binds
  `127.0.0.1:0` (loopback interface, ephemeral port) —
  `native/src/tunnel.rs`.
- **Restrictive credential files.** Client config files that must hold secrets
  (e.g. Remmina `.remmina`) are written `0600` and cleaned up, with a sweep for
  stale files (`native/src/rdp_client/utils.rs`).
- **Log redaction.** Diagnostic exports pass through
  `redact_sensitive` to strip tokens, passwords and API keys
  (`native/src/redact.rs`).
- **Path-traversal rejection & local write jail.** Remote paths reject `..`
  components; local downloads are constrained to the user's home
  (`native/src/sftp.rs`).
- **Transfer size limit.** File transfers are capped (`MAX_FILE_SIZE`) to bound
  disk/DoS exposure (`native/src/sftp.rs`).

The full analysis — including honest **residual risks** (same-UID access to the
loopback listener, plaintext password persisted in a `0600` `.remmina` file
until cleanup, `gcloud` resolved via `PATH`) and the planned hardening — lives in
[docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Scope & assumptions

LCC trusts the local machine and the local user account it runs as. An attacker
who already has code execution as the same UID is largely outside the current
threat model (see the threat model for the specific residual items we are
hardening anyway). LCC delegates VM-level authentication and authorization to
Google IAP and the target host; it does not implement its own access-control
plane.
