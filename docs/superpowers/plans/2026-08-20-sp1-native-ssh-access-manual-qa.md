# QA manual — SP-1: acceso SSH nativo

**Build:** (rellenar con el `kBuild` probado)
**Requisito:** `LCC_AUTH_ENGINE=native`.

## Entorno hostil (para los ítems 3 y 4)

`native/src/gcloud_bin.rs::resolve()` busca el binario en este orden: primero
`$HOME/google-cloud-sdk/bin` (el layout del instalador interactivo/tarball de
Google), luego una lista fija `KNOWN_DIRS` (entre ellas
`/usr/lib/google-cloud-sdk/bin`, el layout del paquete apt), y solo al final
`$PATH`. El sandbox tiene que enmascarar **todas** las rutas donde tu propio
`gcloud` pueda vivir, no solo la que resulte tener la máquina en la que se
escribió esta receta — si te falta una, `gcloud` sigue siendo alcanzable
dentro del `bwrap` y el ítem 3 pasa en verde sin haber probado nada. Antes de
lanzar el sandbox, mira dónde está tu `gcloud` (`command -v gcloud`,
`readlink -f "$(command -v gcloud)"`) y compáralo con `resolve()`; si tu
instalación vive en otro sitio de `KNOWN_DIRS` o en un `$PATH` no estándar,
añade también ese `--tmpfs`.

```bash
pkill -f lightweight_cloud_connector; sleep 2
bwrap --dev-bind / / \
  --tmpfs "$HOME/google-cloud-sdk" \
  --tmpfs /usr/lib/google-cloud-sdk \
  --tmpfs "$HOME/.config/gcloud" \
  sh -c '
  echo "gcloud: $(command -v gcloud || echo NINGUNO)"
  exec env LCC_AUTH_ENGINE=native ./build/linux/x64/release/bundle/lightweight_cloud_connector'
```

Verificable **después** del hecho, que es lo que lo hace inmune a errores de
secuencia — pero el PID hay que identificarlo con cuidado: un grep ingenuo del
binario también encuentra la propia shell que lo lanzó, porque su línea de
comandos contiene esa misma ruta, y esa shell sí tiene `/usr/bin/gcloud`. Lo
que distingue al proceso sandboxeado no es el grep, es que su `/proc/$P/ns/mnt`
difiere del de la shell:

```bash
readlink /proc/self/ns/mnt                    # el namespace del host
ps -eo pid,args | grep -F 'release/bundle/lightweight' | grep -v grep
# el PID cuyo /proc/$P/ns/mnt DIFIERE del del host es el proceso sandboxeado
readlink /proc/$P/ns/mnt                      # comparar con la línea de arriba
test -e /proc/$P/root/usr/bin/gcloud          # no debe existir
ls /proc/$P/root/"$HOME"/.config/gcloud/      # no debe existir
```

## 1. Ruta rápida: la clave de gcloud ya vale

- [ ] Con `~/.ssh/google_compute_engine` presente y autorizada, abrir SFTP
      **no** muestra el diálogo de consentimiento y conecta.

**Evidencia:** el log no contiene `Published LCC's SSH key`, y los metadatos de
la VM no ganan ninguna entrada nueva:

```bash
gcloud compute instances describe <VM> --zone=<ZONA> \
  --format="value(metadata.items.filter(\"key:ssh-keys\").extract(\"value\"))" | grep -c lightweight-cloud-connector
```

Debe dar `0`. Si da `1`, se provisionó sin necesidad y la ruta rápida no
funciona.

*(Comprobado el 2026-08-23: el escapado `\"` dentro de las comillas dobles de
`--format="..."` es válido en bash — `\"` dentro de una cadena entrecomillada
produce una comilla literal sin cerrar la cadena, así que el comando llega a
`gcloud` como `--format=value(metadata.items.filter("key:ssh-keys").extract("value"))`,
que es lo que se pretendía. El comando no se ha ejecutado contra una VM real
en este entorno — no hay ninguna alcanzable y las credenciales de `gcloud`
están caducadas — así que solo el citado de shell está verificado, no el
comportamiento contra GCP.)*

## 2. Provisionado con consentimiento

Retira temporalmente la autorización (mueve `~/.ssh/google_compute_engine` y
`~/.ssh/id_*` fuera, y vacía el agente con `ssh-add -D`).

- [ ] Abrir SFTP muestra el diálogo, nombrando el proyecto y la huella.
- [ ] Al autorizar, la conexión se establece.

**Evidencia:** el log dice `Published LCC's SSH key to the instance metadata`
con la huella, y el `grep` de arriba pasa a dar `1`. En la consola de GCP la
entrada aparece con el comentario `lightweight-cloud-connector`.

## 3. Sin gcloud, desde cero

En el sandbox, y con las claves personales retiradas como en el ítem 2:

- [ ] SFTP conecta tras autorizar.
- [ ] Un reenvío SSH al 8443 se establece.

**Evidencia:** `/proc/$P/root/usr/bin/gcloud` inexistente, más las dos líneas
del log. Es el criterio de corte de SP-1.

## 4. La denegación se recuerda

El diálogo ya **no** se puede cerrar con Esc ni tocando fuera de él
(`barrierDismissible: false`): la única forma de rechazar es pulsar "Ahora
no" a propósito.

- [ ] Con el diálogo abierto, pulsar Esc y tocar fuera del diálogo: en ambos
      casos el diálogo sigue en pantalla, sin cerrarse ni contar como
      respuesta.
- [ ] Pulsar "Ahora no" deliberadamente deja SFTP sin conectar, con un
      mensaje que ofrece las dos salidas reales: pedir a un administrador
      que autorice la clave, o abrir el puerto en la regla de firewall de
      IAP y usar un túnel directo. (El mensaje ya no menciona autorizar
      "desde el menú de conexión de la VM" — ese menú nunca existió.)
- [ ] Reintentar **no** vuelve a mostrar el diálogo.

**Evidencia:** el diálogo sigue visible tras Esc/clic fuera; el mensaje en
pantalla tras "Ahora no" (con las dos salidas citadas arriba); y que el
segundo intento no abre diálogo.

## 5. No se destruyeron las claves de otros

Con una VM que ya tenga entradas `ssh-keys` de otro usuario, **antes** y
**después** de provisionar:

```bash
gcloud compute instances describe <VM> --zone=<ZONA> \
  --format="value(metadata.items.filter(\"key:ssh-keys\").extract(\"value\"))"
```

- [ ] Todas las entradas previas siguen ahí, y la nuestra se añadió.

**Evidencia:** las dos salidas, comparadas. **Este es el ítem que no se puede
saltar:** perder las claves de otros en un proyecto compartido es un incidente.

## 6. Permisos insuficientes

Con una cuenta sin `compute.instances.setMetadata` sobre la VM:

- [ ] El mensaje nombra el permiso que falta y las dos salidas reales.

**Evidencia:** el texto en pantalla, que debe contener
`compute.instances.setMetadata`. Un mensaje genérico es un fallo del ítem.

## 7. OS Login

Si hay una VM con `enable-oslogin=TRUE` a mano:

- [ ] SFTP conecta, y el usuario es el POSIX (`usuario_dominio_com`), no el
      local.
- [ ] **Un reenvío SSH también conecta**, con el mismo usuario POSIX. No
      basta con probar SFTP y el terminal: una revisión encontró que el
      reenvío descartaba el nombre de usuario provisionado y autenticaba
      como el `$USER` local, lo que falla exactamente en una VM con OS
      Login. Ya está corregido, pero vivía en la única ruta que este
      checklist no cubría antes — por eso ahora la cubre.

**Evidencia, y no es la misma para las tres rutas.** SFTP y el reenvío
autentican por libssh2 y dejan la línea del log: `Creating SSH session` (o
`Creating SSH session with a single explicit key`, que es la variante que se
usa cuando ya se conoce la clave válida) con `username=` mostrando el POSIX.

El terminal **no** deja esa línea: no llama a `ssh_session.rs`, lanza el
`ssh(1)` del sistema en un pty. Pedirle esa línea era pedirle una evidencia
que no puede producir. Lo que sí produce es su propia línea de comandos, que
además enseña de paso la clave que presenta:

```bash
ps -eo pid,args | grep -F 'ssh -p' | grep -v grep
```

- [ ] La línea del `ssh` lanzado por LCC termina en `<POSIX>@localhost` (no
      en tu `$USER`), y —si la VM se acaba de provisionar— lleva
      `-i .../lightweight_cloud_connector/ssh/lcc_ed25519` junto con
      `-o IdentitiesOnly=yes`.

**Si no hay ninguna VM con OS Login disponible, di que el ítem quedó sin
verificar** — no lo marques en verde por analogía.

## 8. Con las claves del usuario y el agente EN SU SITIO

Los ítems 2 y 3 te mandan apartar `~/.ssh/id_*` y vaciar el agente con
`ssh-add -D`. Eso deja la clave de LCC como única candidata, así que **ese
entorno no puede detectar el fallo que este ítem busca**: que la clave de LCC
se ofrezca la última y no le quede presupuesto. `MaxAuthTries` de `sshd` vale
6 por defecto, y un usuario con dos o tres identidades en el agente más un
par de claves en `~/.ssh` lo agota antes de llegar a la de LCC.

Prepara el entorno al revés que en el ítem 2 — con todo puesto — sobre una VM
donde LCC **sí** haya tenido que provisionar (ítem 2 o 3 ya ejecutado):

```bash
ssh-add -l                 # que haya identidades cargadas: 2 o más
ls ~/.ssh/id_*             # y claves propias en su sitio, ninguna autorizada en la VM
```

- [ ] SFTP conecta y lista el directorio remoto.
- [ ] Un reenvío SSH al 8443 se establece.
- [ ] El terminal SSH abre sesión.

**Evidencia:** las tres rutas conectan con el agente cargado y las claves
propias presentes. Un `All SSH authentication methods failed` justo después
de que el provisionado dijera que todo fue bien es exactamente el fallo del
ítem. Para el terminal, además, el `ps` del ítem 7: tiene que llevar `-i` y
`IdentitiesOnly=yes`.

## Conocidos, no defectos

- **No hay forma en la UI de deshacer un rechazo deliberado.**
  `setSshProvisionConsent` tiene una sola llamada, la del propio diálogo. Un
  usuario que pulsa "Ahora no" no tiene manera de volver atrás desde dentro
  de la app; la vía del administrador sigue funcionando, porque la sonda se
  ejecuta antes de consultar el flag recordado, así que el proyecto empieza
  a funcionar en cuanto alguien autoriza su clave — sin que haga falta tocar
  nada en LCC.
- **SSHFS ya pasa por la puerta de consentimiento (arreglado el 2026-08-25).**
  Era el cuarto punto de entrada SSH y el único que SP-1 dejó fuera: no pedía
  consentimiento, pasaba `identityFile: null` —así que no podía presentar la
  clave de LCC, que no vive en `~/.ssh`— y precargaba el usuario mangleando el
  email en vez de resolver la cuenta real. Los tres quedan corregidos, y la
  clave se acompaña de `IdentitiesOnly=yes` para que el agente no agote
  `MaxAuthTries` antes de ofrecerla.

  **Añade esto al QA:** monta por SSHFS en una VM donde LCC haya provisionado
  la clave, con tu agente cargado y tus claves personales en su sitio. El campo
  de usuario debe aparecer ya relleno con la cuenta correcta —bajo OS Login,
  la POSIX, no tu `$USER`— y el montaje debe funcionar. Evidencia:
  `ps -eo args | grep sshfs` mostrando **`IdentityFile=`** y
  **`IdentitiesOnly=yes`** en la línea del proceso.
## Cierre

1. `cd native && cargo test --lib` — verde. `cargo build --lib` — sin warnings.
2. `flutter analyze` — cero líneas `error •`.
3. `flutter test` — `All tests passed!`
4. Subir `kBuild` en `lib/src/version.dart`, `cargo build --release` y `flutter build linux --release`.
5. Revisión final de todo el rango del plan.

El **criterio de corte** es el ítem 3 del checklist —sin gcloud, desde cero,
SFTP y reenvío— junto con el ítem 5, que es el que protege a los demás usuarios
del proyecto. Ninguno de los dos es opcional.
