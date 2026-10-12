# Manual QA — Dedup port-reuse warning

Run on a real desktop with a reachable GCP VM.

- [ ] Open a Custom Tunnel (Direct) choosing local port A for a VM:remote → success snackbar "Túnel listo en 127.0.0.1:A".
- [ ] With that tunnel still up, open the Custom Tunnel again for the SAME VM:remote choosing a DIFFERENT local port B → the warning snackbar appears ("Se reusó un túnel existente en 127.0.0.1:A; el puerto B que pediste no se aplicó"), stays ~6s, and Copy still copies 127.0.0.1:A.
- [ ] Same two steps in SSH forward mode → the warning appears there too.
- [ ] Open a Custom Tunnel with a chosen port for a VM:remote that has NO existing tunnel → normal success message (no warning).
- [ ] Open a Custom Tunnel in AUTO mode (leave local port empty) for a VM:remote that already has a tunnel → normal success message on the reused port (no warning — you didn't request a specific port).
- [ ] Spanish and English locales both render the warning text correctly with the address and requested port.
