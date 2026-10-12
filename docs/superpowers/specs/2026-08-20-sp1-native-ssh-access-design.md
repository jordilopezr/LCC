# SP-1 — Acceso SSH nativo: claves y usuario (spec de diseño)

**Fecha:** 2026-08-20
**Rama:** `27H1-Preview`
**Contexto:** prerequisito de **D5**, descubierto durante el QA de D4
**Roadmaps:** [SG-D](2026-08-12-sgd-oauth-roadmap.md) · [salida de gcloud](2026-08-12-gcloud-removal-roadmap.md)

## Por qué existe este sub-proyecto

El reenvío SSH (`gcloud compute ssh -L`, `spawn_ssh_forward` en
`native/src/tunnel.rs`) es **la única vía a los puertos que la regla IAP no abre**.
En el proyecto de pruebas, `acceso-iap` abre solo `tcp:22`, así que 8443 y 3000 —los
de uso diario— solo se alcanzan montando el forward dentro del 22.

Ningún sub-proyecto de la iniciativa lo retira, pero **D5 lo rompe igual**: usa las
credenciales del propio CLI, y cuando LCC deje de ejecutar `gcloud auth login` nadie
las renovará. Ya se observó el 2026-08-19: `gcloud compute ssh` abortando con
*"Reauthentication failed. cannot prompt during non-interactive execution"* mientras
LCC listaba proyectos sin problema con su token nativo.

**Conservar gcloud solo para SSH no es una salida:** obligaría a conservar la auth de
gcloud, que es justo lo que D5 elimina.

**Abrir los puertos en el firewall tampoco lo es**, aunque para un usuario con control
sobre sus reglas sería más barato que este sub-proyecto: LCC se distribuye como
software libre, y sus usuarios no pueden cambiar el firewall de su organización.

## Decomposición: SP-1 y SP-2

| | Qué | Depende de |
|---|---|---|
| **SP-1** (este spec) | Claves y usuario: adoptar, generar, provisionar, consentimiento | — |
| **SP-2** | Promover `ssh_forward.rs` a defecto y escribir sus guardas. **Ya no retira `spawn_ssh_forward`**: la decisión del 2026-08-21 conserva el motor gcloud como escotilla seleccionable | SP-1 |

Separarlos importa: **SP-1 arregla un fallo que ya existe hoy** (ver abajo) y se puede
entregar solo. SP-2 sin SP-1 no funciona, porque el motor nativo se queda sin
credenciales.

## El fallo latente que SP-1 arregla

`get_current_username()` (`native/src/sftp.rs:1038`) devuelve el `$USER` local, y es
lo que usan hoy SFTP y el terminal SSH. Funciona **por coincidencia**: gcloud
provisiona en metadatos con ese mismo nombre.

Contra una VM con **OS Login activo**, el usuario correcto sería el POSIX
(`jlopezre_ntt_enap_cl`), no `jlopezre` — así que SFTP y el terminal fallan.
`email_to_oslogin_username` existe en el bridge (`native/src/api.rs:177`) y **no la
llama nadie**. La detección de OS Login, en cambio, ya está hecha:
`GcpInstanceClientLib.os_login_enabled` la expone por instancia.

## Decisiones tomadas (y por qué)

### Adoptar primero, generar solo si no hay acceso

Quien haya usado `gcloud compute ssh` alguna vez tiene
`~/.ssh/google_compute_engine` **ya autorizada** en sus VMs. Añadir ese nombre a los
candidatos de `create_ssh_session` da a esos usuarios una ruta rápida sin provisionar
nada. El provisionado real solo hace falta para quien nunca usó gcloud — que es
exactamente el usuario objetivo después de D5.

**Se adopta lo que está autorizado, no lo que se llama de cierta forma:** la
comprobación es un intento de sesión real, no la existencia de un fichero.

### Metadatos de **instancia**, no de proyecto

`gcloud compute ssh` escribe por defecto en los metadatos del **proyecto**: una
escritura y entras en todas las VMs, presentes y futuras. En un proyecto compartido
—el caso de `project-shared-backup`— eso es tocar estado común y exige permiso sobre
el proyecto entero.

A nivel de instancia el radio de impacto es la máquina a la que te conectas, el
permiso necesario es `compute.instances.setMetadata` sobre ella, y se esquiva una
trampa: muchas organizaciones ponen `block-project-ssh-keys=TRUE` en las VMs
sensibles, y ahí una clave de proyecto no sirve aunque se escriba.

### Consentimiento la primera vez, por proyecto

Provisionar es **escribir en la infraestructura del usuario**. `gcloud` lleva años
haciéndolo sin preguntar, pero LCC se distribuye, y "modifiqué tu VM y no te lo dije"
es un reporte de seguridad esperando a ocurrir: la entrada queda visible en la consola
de GCP con el nombre de quien la puso.

Se pregunta **una vez por proyecto** y se recuerda. Escribimos por instancia, pero
preguntar en cada VM sería insufrible; el diálogo explica que aplica a las máquinas de
ese proyecto según el usuario se vaya conectando, qué se escribe y cómo retirarlo.

Esto sigue cumpliendo "el usuario no configura nada": no hay que **preparar** nada,
solo aceptar una vez.

La decisión se guarda en el almacenamiento de Dart (`StorageService`), por id de
proyecto. **Si el usuario deniega**, se recuerda igual y las funciones que necesitan SSH
reportan el mismo error accionable que un fallo de permisos —qué falta y cuáles son las
salidas—, sin volver a preguntar en cada conexión. Un "no" que se pregunta otra vez a
los treinta segundos no es un consentimiento, es acoso.

### Clave generada en Rust puro

`ed25519` con el crate **`ssh-key`** (RustCrypto), en formato OpenSSH. **No** se invoca
`ssh-keygen`: añadir una dependencia de CLI a un proyecto cuyo propósito es quitar una
sería contradictorio.

### La clave de LCC no se escribe en `~/.ssh`

La privada vive en `<app data dir>/ssh/lcc_ed25519` con modo `0600`, junto a
`oauth_accounts.json` (`app_dirs::migrated_app_dir(dirs::data_local_dir())`). `~/.ssh`
es del usuario y LCC no tiene por qué escribir ahí sin pedirlo.

### La clave provisionada no caduca

La entrada de metadatos se escribe sin `expireOn`, como hace `gcloud compute ssh`.
Una clave con caducidad obligaría a lógica de reprovisionado y a confiar en el reloj,
a cambio de una limpieza que en la práctica nadie observa.

**A cambio, la entrada es identificable:** lleva el comentario
`lightweight-cloud-connector` para poder encontrarla y borrarla, y el spec documenta
cómo retirarla. Auditabilidad sin la complejidad de la caducidad.

## Arquitectura

Módulo nuevo `native/src/ssh_access.rs`, con **dos fases** —averiguar y escribir—
porque el consentimiento tiene que ocurrir entre medias:

```
Dart (SftpTab / SshTerminalTab / reenvío)
   │
   ├─► probe_ssh_access(project, zone, instance)
   │      └─ Ready { username }                    → conectar
   │      └─ NeedsProvisioning { username, method, key_fingerprint }
   │             │
   │             ├─ consentimiento ya dado para el proyecto ─┐
   │             └─ diálogo (una vez por proyecto) ──────────┤
   │                                                         ▼
   └─► provision_ssh_access(project, zone, instance) → SshAccess { username }
```

### Superficie

```rust
pub enum SshAccessState {
    Ready { username: String },
    NeedsProvisioning { username: String, method: ProvisionMethod, key_fingerprint: String },
}

pub enum ProvisionMethod { OsLogin, InstanceMetadata }

pub struct SshAccess { pub username: String }

pub async fn probe_ssh_access(project: &str, zone: &str, instance: &str) -> Result<SshAccessState>
pub async fn provision_ssh_access(project: &str, zone: &str, instance: &str) -> Result<SshAccess>
```

`key_fingerprint` es el de **nuestra** clave pública, para que el diálogo pueda
mostrarlo: es lo que el usuario verá luego en la consola de GCP.

### Cómo decide `probe`

1. Determina el usuario candidato (ver abajo).
2. Abre un túnel IAP **nativo** al `:22` y llama a `crate::ssh_session::create_ssh_session`.
3. Autentica ⇒ `Ready`. Falla la autenticación ⇒ `NeedsProvisioning`.

Un fallo que **no** sea de autenticación (la VM no responde, el relay no llega) se
propaga como error: no es un caso de provisionado y tratarlo como tal escondería el
problema real.

### Elección de usuario

| Modelo | Usuario |
|---|---|
| OS Login activo | El POSIX que devuelve `GET oslogin.googleapis.com/v1/users/{email}/loginProfile` (`posixAccounts[].username`) |
| Metadatos | El `$USER` local, que es lo de hoy y lo que asume gcloud |

Se consulta el perfil en vez de derivar el nombre porque la derivación
(`email_to_oslogin_username`) **no siempre acierta**: el POSIX real puede llevar sufijo
por colisión o venir fijado por la organización. La derivación queda como respaldo si
el perfil no trae `posixAccounts`.

## Publicación

**OS Login:** `POST https://oslogin.googleapis.com/v1/users/{email}:importSshPublicKey`

**Metadatos de instancia**, en tres pasos que no se pueden separar:

1. `GET .../instances/{instance}` — devuelve `metadata.fingerprint` y los `items`.
2. Fusionar nuestra entrada con el valor actual de `ssh-keys`.
3. `POST .../instances/{instance}/setMetadata` con `{ fingerprint, items }`.

El `fingerprint` es **obligatorio**: GCP lo usa para concurrencia optimista y rechaza
la escritura sin él o con uno viejo.

### La fusión es la parte peligrosa

`ssh-keys` es un único valor de texto con una entrada por línea, de forma
`usuario:tipo clave comentario`. **Sobrescribirlo en vez de fusionarlo borra el acceso
de todos los demás.** En un proyecto compartido eso es un incidente, no un bug.

La fusión es una función pura y lleva las guardas más duras del sub-proyecto:

- valor ausente o vacío
- entradas de otros usuarios, que deben sobrevivir intactas
- nuestra entrada ya presente, que no debe duplicarse
- entradas con `google-ssh {"expireOn":...}`, que no deben corromperse al reescribir

### Propagación

El agente invitado tarda unos segundos en recoger la clave nueva, así que
**`provision_ssh_access` no devuelve `Ok` hasta que una sesión real autentica**: publica,
y luego reintenta la sesión con espera acotada. Devolver en cuanto la escritura responde
haría fallar la primera conexión justo después de un provisionado correcto, que es el
peor momento posible para un mensaje de error.

Agotado el plazo sin autenticar, el error dice que la clave se escribió pero la VM aún
no la ha recogido, y sugiere reintentar — un estado distinto de "no se pudo escribir",
y el usuario merece poder distinguirlos.

## Errores

El fallo más probable en una app distribuida es **de permisos**: mucha gente no tiene
`compute.instances.setMetadata` ni permiso de OS Login sobre el proyecto.

Ese caso se traduce nombrando **el permiso exacto que falta** y las dos salidas reales
—pedir al administrador que autorice la clave, o abrir el puerto en el firewall para
usar el túnel directo—, no un mensaje genérico. Es la misma lección del barrido de
túneles: un código genérico manda al usuario a mirar donde no es.

## Scopes

Ninguno nuevo. `SCOPES` ya incluye `https://www.googleapis.com/auth/cloud-platform`
(`native/src/oauth.rs:25`), que cubre Compute y OS Login. No hay que volver a pasar por
la pantalla de consentimiento de Google.

## Pruebas

**Puras, sin red:**

- **La fusión de `ssh-keys`**, con los cuatro casos feos de arriba. Lleva además una
  **prueba negativa explícita: si la función sobrescribe en vez de fusionar, el test
  falla.** Dado lo que cuesta ese error en un proyecto compartido, es la guarda que no
  puede faltar.
- La elección de usuario dados `(os_login_enabled, perfil OS Login, usuario local)`.
- La máquina de estados del consentimiento: no dado / dado para el proyecto / denegado.
- Que la generación produce un par ed25519 válido en formato OpenSSH, y que la privada
  se escribe con modo `0600`.

**Lo que no se puede probar sin una VM:** el provisionado real y la propagación. Van al
QA manual, con el estándar de evidencia de la iniciativa: la entrada visible en la
consola de GCP con el comentario `lightweight-cloud-connector`, y la sesión
estableciéndose después.

## Fuera de alcance

- Promover `ssh_forward.rs` a defecto (**SP-2**). `spawn_ssh_forward` se conserva: ver la decisión del 2026-08-21 en el roadmap de salida de gcloud.
- Metadatos a nivel de **proyecto**.
- Claves con caducidad y su reprovisionado.
- Windows y macOS: el diseño no los excluye, pero el QA de este sub-proyecto es Linux.
- Retirar `email_to_oslogin_username` del bridge, aunque quede casi vestigial (SG-E).

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Borrar las claves de otros al escribir `ssh-keys` | Fusión pura con prueba negativa; escritura a nivel de instancia, nunca de proyecto |
| El usuario no tiene permiso para provisionar | Mensaje que nombra el permiso y las dos salidas reales; no se reintenta en bucle |
| `probe` cuesta segundos porque abre una sesión de verdad | Es el precio de adoptar solo lo que está autorizado; se hace una vez por instancia y se puede cachear en sesión |
| Escribir en la infraestructura del usuario sin que lo espere | Consentimiento por proyecto, con lo que se escribe y cómo retirarlo |
| La clave queda autorizada indefinidamente | Comentario identificable y retirada documentada; la caducidad se descartó a conciencia |
