# Manual QA — Native ssh2 SSH port forward (opt-in)

Launch the app with `LCC_SSH_FORWARD_ENGINE=native` and a reachable GCP VM whose
SSH key is already accepted (the same key SFTP uses). Compare against the
default (unset) gcloud path.

- [ ] Default (env unset): SSH-forward mode still works via `gcloud compute ssh -L` (no regression).
- [ ] `native`: open an SSH forward (Custom Tunnel → SSH forward) to a service on the VM (e.g. a DB on 5432 or a localhost-only web UI). It connects on the local port (chosen or auto).
- [ ] Data flows correctly through the forward (query the DB / load the page) — no truncation or hangs.
- [ ] Multiple concurrent connections through the same forward work (e.g. two DB clients).
- [ ] Choosing a fixed local port binds exactly that port; an occupied port gives a clean error.
- [ ] The forward appears in the Tunnel Manager and Disconnect stops it (port released; no leaked thread/process).
- [ ] Idle: after the reaper timeout with no active connection, the forward is reaped and its port freed.
- [ ] A VM whose key is NOT accepted → the forward fails with the ssh2 auth error (documented limitation: native does not auto-provision keys).
- [ ] A client that receives the server's FIN but never closes its own write side: the connection lingers until the idle reaper reaps the whole forward (edge case; verify the reaper still cleans it up).
