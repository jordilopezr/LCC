# Manual QA — Choose local port for Custom Tunnel

Run on a real desktop with a reachable GCP VM.

- [ ] Custom Tunnel → Direct (IAP) mode: leave "Local port" empty → connects on an auto-assigned port (as before).
- [ ] Custom Tunnel → Direct (IAP) mode: type a free local port (e.g. 15900) → success snackbar reads `127.0.0.1:15900`.
- [ ] Custom Tunnel → SSH forward mode: type a free local port → forward established on exactly that port.
- [ ] Type a local port already in use → clear error dialog ("Local port N is not available: …" / localizedError), not a silent failure.
- [ ] Type a non-numeric / out-of-range value → inline field error, Connect disabled.
- [ ] Reopen the dialog for a VM:port that already has a tunnel and pick a different local port → returns the existing tunnel's port (dedup), shown truthfully in the snackbar.
- [ ] Spanish locale: the field reads "Puerto local (opcional)" with hint "Vacío = automático".
