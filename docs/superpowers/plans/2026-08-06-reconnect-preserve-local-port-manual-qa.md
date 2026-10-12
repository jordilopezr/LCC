# Manual QA — Reconnect preserves the chosen local port

Run on a real desktop with a reachable GCP VM.

- [ ] Open a Direct (IAP) Custom Tunnel and choose a fixed local port (e.g. 15901). Confirm it connects on 15901.
- [ ] Leave it idle until the Rust reaper reaps it (idle timeout), so the health check enters "reconnecting".
- [ ] After auto-reconnect: the tunnel is back on the SAME port 15901 (not a new auto port).
- [ ] Open a Direct Custom Tunnel WITHOUT choosing a local port (auto). Force a reap/reconnect → it reconnects on some auto port (no regression; no error).
- [ ] While a chosen-port tunnel is reconnecting, hold that local port with another process → reconnect fails and retries/gives up with the existing notification (it does not silently move to a different port).
- [ ] Disconnect the chosen-port tunnel explicitly, then reconnect a fresh one on an auto port for the same VM:remote → no stale chosen port is reused.
- [ ] Let a chosen-port tunnel exhaust its reconnect attempts (give up) WITHOUT explicitly disconnecting, then reopen the Custom Tunnel for the same VM:remote choosing AUTO → it connects on an auto port, and a later idle-reap reconnects on an auto port (the old chosen port is NOT reused).
