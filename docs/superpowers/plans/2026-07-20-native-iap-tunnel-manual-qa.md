# Manual QA — native IAP tunnel (27H1)

Run each check with `LCC_TUNNEL_ENGINE=native` so a silent fallback cannot mask a failure.

- [ ] SSH session over the tunnel opens and stays usable for several minutes.
- [ ] RDP session to a Windows VM connects and renders.
- [ ] SFTP browser lists, uploads and downloads a file.
- [ ] Large transfer (>50 MB, e.g. `scp`) completes with a correct checksum — exercises chunking and ACKs.
- [ ] Briefly drop the network (disable Wi-Fi ~5 s): the session resumes without restarting the tunnel.
- [ ] Tunnel Manager shows the tunnel healthy, and Disconnect actually closes the local port.
- [ ] Force an error: revoke the IAP role or target a stopped VM, and confirm the dialog shows the localized message (check both English and Spanish) rather than a raw code.
- [ ] Compare with `LCC_TUNNEL_ENGINE=gcloud` that behaviour is equivalent.
