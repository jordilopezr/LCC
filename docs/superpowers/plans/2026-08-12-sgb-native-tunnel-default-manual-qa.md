# QA manual — SG-B: túnel IAP directo nativo por defecto

El túnel IAP directo usa ahora el motor **nativo por defecto** (sin `LCC_TUNNEL_ENGINE`).
Establecer túneles reales no es unit-testeable; verificar a mano contra una VM real.

Con el default (sin variable de entorno) — todo debe ir por el motor **nativo**:
- [ ] Conectar RDP a una VM Windows funciona.
- [ ] Conectar VNC funciona.
- [ ] SSH embebido (pestaña) conecta.
- [ ] SFTP (pestaña) abre y lista archivos.
- [ ] Custom Tunnel en **modo directo** (IAP) a un puerto arbitrario conecta.
- [ ] Reconexión de un túnel tras caída y **reuso del puerto local** elegido funcionan.
- [ ] (Opcional, logs) el log muestra `engine = "native"` al establecer el túnel.

Escotilla de opt-out:
- [ ] Con `LCC_TUNNEL_ENGINE=gcloud`, el túnel directo se establece por gcloud (`engine = "gcloud"`), como antes.
- [ ] Con el nativo, si el túnel falla, aparece el error localizado (no cae a gcloud en silencio).

Sin cambios en esta fase:
- [ ] El SSH forward (`-L`) sigue funcionando por gcloud por defecto.
