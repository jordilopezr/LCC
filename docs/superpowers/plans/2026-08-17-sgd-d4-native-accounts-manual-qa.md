# QA manual — D4: gestión de cuentas nativa

**Build:** (rellenar con el `kBuild` que se pruebe)
**Requisito:** lanzar la app con `LCC_AUTH_ENGINE=native`.

> **Precondición — no hay primer login nativo todavía.** Con
> `LCC_AUTH_ENGINE=native` y el almacén de tokens **vacío** no existe entrada
> desde la UI: `execute_login` sigue delegando en `gcloud auth login`, y el
> primer login nativo es trabajo de D5, no de D4. El tester **debe** llegar ya
> con al menos una cuenta en el almacén nativo, de las pruebas de D1/D3. Si
> `oauth_accounts.json` no existe o está vacío, esta checklist no se puede
> ejecutar: consíguete primero una cuenta en el almacén.

Cada ítem nombra la evidencia que lo demuestra. Un ítem sin esa evidencia
**no está verificado**, por muy bien que se vea la pantalla.

## Preparación

```bash
# Índice de cuentas nativo
find ~/.local/share -name oauth_accounts.json 2>/dev/null
# Cuentas que conoce gcloud
gcloud auth list
```

Anota ambas salidas **antes** de empezar. La prueba central es que difieran.

## 1. Divergencia: gcloud tiene una cuenta que el almacén nativo no

- [ ] Existe en `gcloud auth list` una cuenta que **no** aparece en
      `oauth_accounts.json`.
- [ ] Esa cuenta **no** aparece en el diálogo de cuentas de la app.

**Evidencia:** las tres salidas a la vez — `gcloud auth list`, el contenido de
`oauth_accounts.json`, y la lista en pantalla.
**Si las tres coinciden, esta prueba no vale.** En esta iniciativa la UI ya
mostró una vez la cuenta corporativa de gcloud mientras el token era de una
cuenta personal del almacén nativo: coincidieron por azar, no por integración.

## 2. Divergencia en el otro sentido

- [ ] Hay en `oauth_accounts.json` una cuenta que **no** está en
      `gcloud auth list`.
- [ ] Esa cuenta **sí** aparece en el diálogo.

**Evidencia:** las mismas tres salidas.

## 3. Entorno hostil: sin gcloud al alcance de la app

**`PATH` no sirve para esto.** `native/src/gcloud_bin.rs::resolve()` prueba
primero `~/google-cloud-sdk/bin` y luego la lista `KNOWN_DIRS` —que incluye
`/usr/bin`, `/usr/local/bin` y `/snap/bin`— **antes** de mirar `$PATH`. Lanzar
con `PATH=/usr/bin:/bin` no esconde nada: la app lo encontraría igual y el ítem
se marcaría en verde sin haber probado nada.

Hay que esconderlo del resolver de la app, no del shell.

**Receta principal — lanzar la app en su propio espacio de montaje con `bwrap`.**
No necesita sudo, no toca nada global, y el enmascarado dura exactamente lo que
dura el proceso, así que no hay forma de desordenar los pasos:

```bash
pkill -f lightweight_cloud_connector; sleep 2
bwrap --dev-bind / / --tmpfs /usr/lib/google-cloud-sdk sh -c '
  echo "gcloud visible para la app: $(command -v gcloud || echo NINGUNO)"
  exec env LCC_AUTH_ENGINE=native \
    ./build/linux/x64/release/bundle/lightweight_cloud_connector'
```

Debe imprimir `NINGUNO` antes de abrir la ventana. Ajusta el `--tmpfs` al
directorio real del SDK en esa máquina (aquí `/usr/bin/gcloud` es un enlace a
`/usr/lib/google-cloud-sdk/bin/gcloud`, así que ocultar el destino deja el
enlace colgando y `is_valid_executable`, que canonicaliza, lo descarta).

**La evidencia más fuerte, y se comprueba en cualquier momento** —incluso
después de la prueba, que es lo que la hace inmune a errores de secuencia:

```bash
PID=$(pgrep -f 'bundle/lightweight_cloud_connector')
test -e /proc/$PID/root/usr/bin/gcloud && echo "ALCANZABLE (mal)" || echo "inalcanzable (bien)"
```

**Por qué NO usar `sudo chmod -x` sobre los binarios**, que era la receta
anterior: es estado global y exige acertar el orden de tres comandos. En la
ejecución del 2026-08-18 dio **dos falsos verdes seguidos** — el túnel se creó
34 s y 27 s *después* de restaurar el bit, y solo se detectó cruzando el log con
`stat -c %z`. Si aun así hay que usarlo, la regla es cruzar **siempre** la hora
del evento en el log con la del último cambio de permisos.

- [ ] **Pre-check:** en el Doctor, la fila de gcloud dice **"no instalado"** y
      los checks que dependen de él salen *Skipped*.
- [ ] La app arranca con sesión: el diálogo de cuentas **lista** las cuentas del
      almacén nativo.
- [ ] Se listan proyectos **y** instancias, y el dashboard **no** muestra la
      pantalla "instala el SDK de gcloud".
- [ ] Un **túnel IAP directo a un puerto que el firewall abra** (típicamente 22)
      se establece.
- [ ] **Prueba negativa:** un **reenvío SSH** en esa misma sesión **falla**. Ese
      modo *es* gcloud; si funciona, el enmascarado no surtió efecto y el resto
      del ítem no vale.

**Evidencia:** la respuesta de la propia app, no `which gcloud` —`which` mira
`$PATH`, y el resolver lo mira el último; cuando discrepan, miente `which`—. Para
el túnel, la línea `Tunnel established ... engine="native"` en el log, con hora
posterior al arranque del sandbox. Sin este ítem la guarda de estado no está
verificada, y es justamente la pieza cuyo fallo sería invisible en la máquina de
desarrollo.

**Resultado 2026-08-19 (build 20260803.26):** PASA. Sandbox verificado en

### 3b. Sin gcloud **y** sin el fichero ADC

El ítem 3 esconde gcloud, pero deja el ADC (`~/.config/gcloud/application_default_credentials.json`)
en su sitio, así que por sí solo no descarta que el token venga de ahí. Esa es
**exactamente** la guarda que faltó en D3, cuyo camino nativo parecía completo y
resultó ser inalcanzable sin ese fichero. Con `bwrap` cuesta un `--tmpfs` más:

```bash
timeout 60 bwrap --dev-bind / / \
  --tmpfs /usr/lib/google-cloud-sdk \
  --tmpfs "$HOME/.config/gcloud" \
  sh -c 'echo "gcloud: $(command -v gcloud || echo NINGUNO)"
         echo "ADC: $(ls ~/.config/gcloud/application_default_credentials.json 2>/dev/null || echo AUSENTE)"
         exec env LCC_AUTH_ENGINE=native ./build/linux/x64/release/bundle/lightweight_cloud_connector'
```

- [ ] La app arranca, se autentica y lista proyectos **e** instancias.

**Cuidado al identificar el proceso:** un `grep` por la ruta del binario captura
también la shell que lo lanzó, porque la ruta está en su línea de comando. Usa el
espacio de montaje para distinguirlos —el de la app difiere del de la shell— y
verifica sobre ese PID:

```bash
readlink /proc/self/ns/mnt                     # el del anfitrión
ps -eo pid,args | grep -F 'release/bundle/lightweight' | grep -v grep
# por cada PID: readlink /proc/$P/ns/mnt   → el que difiera es el sandboxeado
```

**Evidencia:** sobre el PID sandboxeado, `/proc/$P/root/usr/bin/gcloud`
inexistente y `/proc/$P/root/$HOME/.config/gcloud/` inexistente, más las líneas
`✓ Listed N projects` / `✓ Listed N instances` del log posteriores al arranque.
Sin gcloud y sin ADC, la única fuente de credenciales posible es el keyring.

**Resultado 2026-08-20 (build 20260803.26):** PASA. PID 7580 en namespace
`mnt:[4026533460]`, gcloud y `~/.config/gcloud` ausentes en su vista, ADC intacto
en el anfitrión, y `✓ Listed 4 instances` + `✓ Listed 1 projects` a las 14:36:15Z.

`/proc/<pid>/root` antes y después; arranque en frío, 1 proyecto y 4 instancias
por REST, Doctor con gcloud "no instalado" y 7 checks saltados, dashboard
intacto, y `Tunnel established instance="backupmig" remote_port=22
local_port=38567 engine="native"` a las 02:24:21Z.

## 4. Cambiar de cuenta

- [ ] Cambiar a otra cuenta actualiza la marca de activa en el diálogo.
- [ ] Los proyectos que se listan tras el cambio son los de la cuenta nueva.

**Evidencia:** `oauth_accounts.json` muestra el nuevo valor en `active`, y la
lista de proyectos cambia. Si la lista de proyectos **no** cambia, el token
cacheado no se invalidó.

## 5. Añadir una cuenta no cambia la activa

- [ ] Con una cuenta activa, añadir otra abre el navegador y la nueva aparece
      en la lista.
- [ ] La cuenta activa **sigue siendo la anterior**.

**Evidencia:** `active` en `oauth_accounts.json` no cambió; `accounts` tiene una
entrada más.

## 6. Quitar una cuenta revoca de verdad

- [ ] Antes de quitarla, copia su refresh token del keyring:

```bash
secret-tool lookup service linux-cloud-connector username oauth::TU@EMAIL
```

- [ ] **Control negativo — el token funciona ANTES de quitar la cuenta.** Sin
      este paso el ítem no prueba nada: un refresh token guardado puede estar
      muerto ya (revocado en otra sesión, caducado por inactividad, contraseña
      cambiada), y entonces el `curl` de después imprime `invalid_grant` haya
      corrido `revoke_refresh_token` o no.

```bash
# El client_secret de una app de escritorio no es un secreto real —va embebido
# en el binario—, pero no se copia aquí: se lee de la fuente al ejecutar.
SECRET=$(grep -oP 'OAUTH_CLIENT_SECRET: &str = "\K[^"]+' native/src/oauth.rs)
curl -s -X POST https://oauth2.googleapis.com/token \
  -d client_id=743123147934-plp891qo2a44ie5jop1ud7n445gduk0h.apps.googleusercontent.com \
  -d client_secret="$SECRET" \
  -d grant_type=refresh_token -d refresh_token='<el copiado>' | grep access_token
```

      Ese `grep` **tiene que** encontrar un `access_token`. Si no lo encuentra,
      el token ya estaba muerto: **para**, usa otra cuenta o vuelve a iniciar
      sesión con ésta, y repite. Marcar el ítem sin este control es marcarlo en
      falso.

- [ ] Quita la cuenta desde el diálogo.
- [ ] Desaparece de `oauth_accounts.json` y del keyring.
- [ ] El refresh token copiado **ya no sirve** — el mismo `curl` de arriba,
      cambiando solo el `grep`:

```bash
SECRET=$(grep -oP 'OAUTH_CLIENT_SECRET: &str = "\K[^"]+' native/src/oauth.rs)
curl -s -X POST https://oauth2.googleapis.com/token \
  -d client_id=743123147934-plp891qo2a44ie5jop1ud7n445gduk0h.apps.googleusercontent.com \
  -d client_secret="$SECRET" \
  -d grant_type=refresh_token -d refresh_token='<el copiado>' | grep invalid_grant
```

**Evidencia:** las **dos** salidas, en ese orden — un `access_token` antes de
quitar la cuenta y un `invalid_grant` después. Solo el par demuestra que la
revocación ocurrió; el `invalid_grant` a solas es compatible con un borrado
puramente local sobre un token que ya estaba muerto.

## 7. Proyectos por cuenta — NO verificable manualmente en esta build

**Este ítem no se puede ejecutar, y se deja escrito para que el hueco se vea.**

`listProjectsForAccount` no tiene ningún punto de llamada en `lib/` fuera del
puente generado, y `lib/src/features/account_management_dialog.dart` no tiene
UI de proyectos: **no existe el "selector de proyectos por cuenta"** que la
versión anterior de esta checklist pedía pulsar. La ruta nativa `projects_for`
está implementada, pero todavía sin consumidor.

Lo que sí está cubierto, y dónde: que esa ruta no se contamine con el token ni
con la caché de la cuenta activa se verifica en Rust, porque
`list_projects_with_token` recibe el token **como parámetro** en vez de
resolverlo por su cuenta (`native/src/gcp_rest_client.rs`), y los tests de
`native/src/accounts.rs` cubren el despacho.

- [ ] (no aplica — sin UI que ejercite la ruta)

**Evidencia:** ninguna manual. Reabrir este ítem cuando exista UI que llame a
`listProjectsForAccount`; entonces la prueba es la de siempre: dos cuentas con
acceso a proyectos distintos y dos listas distintas.

## 8. No hay regresión con el motor gcloud

Relanza **sin** `LCC_AUTH_ENGINE`:

- [ ] El diálogo de cuentas se comporta exactamente como antes de D4:
      lista, cambia, añade y quita.

**Evidencia:** la lista coincide con `gcloud auth list`, incluida la cuenta que
en el ítem 1 no aparecía.
