# Manual QA — Localized desktop notifications

Enable notifications, set the app language, and trigger events.

- [ ] Spanish: force a tunnel reconnect (let an idle tunnel be reaped, then reconnect) → the desktop notification title/body are in Spanish ("Reconectando túnel…", "Túnel reconectado…").
- [ ] Spanish: a lifecycle op (start/stop a VM) → "✓ start completado: <vm>" / on failure "✗ … falló: <vm>" with the error line.
- [ ] Spanish: launch RDP/VNC where the preferred client is unavailable → "Cliente RDP/VNC de respaldo" + "…Usando <client> en su lugar."
- [ ] English: switch the app language to English and repeat one case → notifications are in English (the original wording, e.g. "IAP Tunnel Failed: <vm>").
- [ ] Change the language while the app is running, then trigger a notification → it uses the newly selected language (the builder refreshed the service's localizations).
- [ ] Raw interpolation preserved: VM states (RUNNING/TERMINATED) and the operation verb appear as-is inside the localized frame.
