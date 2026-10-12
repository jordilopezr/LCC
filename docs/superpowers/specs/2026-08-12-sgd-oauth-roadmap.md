# Roadmap SG-D: login OAuth propio + almacén de tokens (el poste largo)

**Fecha:** 2026-08-12
**Rama:** `27H1-Preview`
**Estado:** Roadmap de secuencia (no es el spec de diseño de una pieza)
**Contexto:** sub-proyecto **SG-D** de la iniciativa de salida de `gcloud` — ver `docs/superpowers/specs/2026-08-12-gcloud-removal-roadmap.md`. SG-A ✔, SG-B ✔.

## Por qué SG-C quedó absorbido aquí

SG-C ("adquisición de token nativa") **no es viable como paso independiente**. La ruta nativa actual (refresco directo del refresh token de ADC, `token_from_adc_refresh` en `native/src/gcp_rest_client.rs`) **falla con `invalid_rapt` en cuentas Workspace/corporativas**; por eso hoy se prefiere `gcloud auth print-access-token` (comentario en `get_access_token`, ~líneas 143-147) — fue el fix del bug `invalid_rapt` de 2026-07.

El motivo de fondo: el refresco de ADC **no tiene a quién pedirle la reautenticación** cuando la política de Workspace la exige. La ruta de token solo se vuelve RAPT-segura **cuando existe un flujo OAuth interactivo propio** al que caer. Ese flujo es SG-D. Por tanto: **la adquisición nativa de token es D3, dentro de SG-D**.

## El plano: cómo lo hace IAP Desktop

IAP Desktop (Google, Apache-2.0, `GoogleCloudPlatform/iap-desktop`) es el caso de referencia — cliente de escritorio con túnel IAP y auth GCP **sin gcloud**:

- **Client OAuth propio embebido**, tipo *Desktop app*: *"This client ID uniquely identifies IAP Desktop"* (`78381520511-…apps.googleusercontent.com`). No usa gcloud.
- **Refresh token cifrado en el almacén del SO**: *"encrypted by using the Windows Data Protection API (DPAPI) and stored in the current user part of the Windows registry"*, y *"allows it to re-authenticate automatically the next time you use it"*.
- **Participa del control de sesión de Workspace**: tiene un ajuste que *"lets you disable reauthentication for IAP Desktop"*.
- **Reauth = relanzar el sign-in interactivo** (patrón estándar de cliente nativo con la librería OAuth de Google): no reimplementa el challenge-response de reauth de gcloud; el login fresco en el navegador satisface la política.

Fuentes: [Privacy & security](https://googlecloudplatform.github.io/iap-desktop/security/) · [Sign-in issues](https://googlecloudplatform.github.io/iap-desktop/troubleshooting-signin/) · [Reauthentication (Google Cloud)](https://docs.cloud.google.com/docs/authentication/reauthentication).

## Lo que LCC ya tiene (de-riesga SG-D)

| Necesidad del plano | Ya presente en LCC |
|---|---|
| Almacén cifrado del refresh token | Crate **`keyring = "3"`** ya en uso (`native/src/windows_credentials/storage.rs`), con **patrón de fichero índice** para enumerar (`load_index`/`add_to_index`). En Linux usa Secret Service (**libsecret**) — análogo de DPAPI. |
| Intercambio de tokens (refresh) | `token_from_adc_refresh` ya hace `grant_type=refresh_token` contra `oauth2.googleapis.com/token` con `reqwest`. |
| PKCE | `rand` + `base64` presentes. **Falta `sha2`** (challenge S256) — dependencia menor. |
| Listener loopback del redirect | `tokio` con feature `net` (basta un `TcpListener` de un solo uso). |
| Abrir el navegador | Patrón `Command::new("xdg-open")` (Linux; ya se lanzan procesos en `gcloud.rs`). |
| Reauth ante RAPT | `reauthenticate()` (`api.rs` ~896) + `GcpSessionBanner` ya existen (sub-proyecto GR): hoy llaman a gcloud; pasarán a llamar al flujo propio. |
| Caché de access token | `TOKEN_CACHE` + TTL + `invalidate_cached_access_token()` ya existen. |

**Conclusión:** SG-D es sobre todo **ensamblar patrones que ya viven en el repo**, más un flujo OAuth nuevo.

## Prerequisito externo (D0 — acción del usuario, no código)

1. **Registrar un client OAuth propio de LCC**, tipo **"Desktop app"**, en un proyecto GCP del usuario. El `client_id` va **embebido** en la app: es público por diseño; los clients de escritorio **no tienen secreto real** — **PKCE** es lo que protege el flujo.
2. **Pantalla de consentimiento / verificación.** El scope `https://www.googleapis.com/auth/cloud-platform` es **sensible**: sin verificación de Google la app muestra el aviso *"Google no ha verificado esta app"* y tiene **tope de ~100 usuarios**. Uso personal / grupo pequeño: sin verificar basta. Distribución pública amplia: requiere el proceso de **verificación OAuth** de Google.

D0 **no bloquea el diseño ni la implementación de D1** (el núcleo es idéntico con o sin verificación; solo cambia la escala de distribución), pero **sí bloquea el QA end-to-end real**.

## Las piezas

### D1 — Núcleo OAuth (Rust) · Riesgo MEDIO-ALTO
Nuevo módulo `native/src/oauth.rs`: flujo **authorization-code + PKCE(S256)** con **redirección loopback** (`http://127.0.0.1:<puerto efímero>`): generar verifier/challenge + `state`, construir la URL de autorización, abrir el navegador, escuchar el redirect de un solo uso, validar `state`, canjear `code`→`{access_token, refresh_token, id_token}`, extraer el **email** del `id_token`. Scope: `cloud-platform` (+ `openid email` para identificar la cuenta).
**Corte:** partes puras testeadas (PKCE S256, construcción de URL, parseo/validación del redirect, extracción de email); flujo completo ejercitable a mano contra el client real (necesita D0).

### D2 — Almacén de tokens (Rust) · Riesgo BAJO
`native/src/token_store.rs`: refresh token **por email** en `keyring` + fichero índice para enumerar cuentas (patrón exacto de `windows_credentials/storage.rs`), y persistencia de **cuál es la cuenta activa**.
**Corte:** guardar/leer/borrar/enumerar cuentas y fijar/leer la activa, con tests.

### D3 — Adquisición de token nativa (Rust) · Riesgo MEDIO
Reconectar `GcpAuthClient::get_access_token` para refrescar desde **D2** en vez de `gcloud auth print-access-token`/fichero ADC, conservando `TOKEN_CACHE`. Un refresh que devuelva error de **reauth** (`invalid_grant`/RAPT) se traduce a la señal de reauth existente → el banner ofrece re-login (que es D1). **Detrás de un flag** para poder validar contra gcloud antes del cutover.
**Corte:** con flag activo, todas las llamadas REST + el túnel funcionan con tokens nativos, incluido tras una reauth forzada. **Aquí muere `invalid_rapt`** (el re-login interactivo lo resuelve).

### D4 — Gestión de cuentas nativa (Rust + bridge) · Riesgo MEDIO
Reimplementar list/switch/add/remove sobre D2 (`add` = flujo D1; `remove` = borrar del keyring). **Mantener estable el interfaz Dart** (`AccountNotifier`/`accountProvider` y los nombres del bridge) para no rehacer la UI. `list_projects_for_account` pasa a REST con el token de esa cuenta.
**Corte:** el diálogo de cuentas funciona sobre el almacén nativo, sin gcloud.
**Evidencia exigida** (ver el estándar de verificación del roadmap de gcloud): la lista mostrada procede de `token_store::list_accounts` y **no** de `listGcloudAccounts` — demostrable porque una cuenta presente en gcloud y ausente del almacén nativo **no** aparece, y viceversa. En esta iniciativa la UI llegó a mostrar la cuenta corporativa de gcloud mientras el token era de una cuenta personal del almacén: coincidieron por casualidad, no por integración.

### D5 — Cutover: nativo por defecto, gcloud como escotilla · Riesgo BAJO-MEDIO

> **Reescrito el 2026-08-21 tras las pruebas con usuarios.** D5 ya no retira la auth de
> gcloud: la conserva como escotilla mantenida por el usuario (opción B del
> [roadmap de salida](2026-08-12-gcloud-removal-roadmap.md#el-motor-gcloud-se-conserva-decisión-del-2026-08-21)).
> Esto **encoge** el sub-proyecto y le baja el riesgo.

**Qué:** nativo pasa a ser el valor por defecto de `LCC_AUTH_ENGINE`; el selector de
motor deja de ser una variable de entorno oculta y pasa a **Ajustes**, con un texto que
diga qué implica elegir gcloud —empezando por que su sesión la mantiene el usuario—.
Retirar `execute_login`/`execute_logout` y `add|remove|list|switch_gcloud_account`: la
gestión de cuentas es nativa desde D4, y bajo la opción B **LCC no invoca la auth de
gcloud en ningún caso**. `reauthenticate()` ya usa el flujo nativo desde 2026-08-18
(commit `9ad273a`). Quitar la dependencia del fichero ADC. Doctor conserva sus checks de
gcloud, degradados a informativos salvo con el motor gcloud seleccionado.

**Corte, en dos mitades que se prueban por separado:**
1. Con el motor **nativo** y `gcloud` inalcanzable —sandbox de `bwrap`, no `chmod`—, LCC
   hace login, gestiona cuentas, lista/gestiona VMs y abre túneles.
2. Con el motor **gcloud** seleccionado y una sesión de CLI válida, la ruta gcloud sigue
   funcionando; y cuando esa sesión caduca, el mensaje dice que hay que ejecutar
   `gcloud auth login` en la terminal, no un error genérico.

La segunda mitad es nueva y es la que evita que la escotilla se pudra. Sin ella, D5
entrega una opción que parece soportada y no lo está.
**Prerequisito descubierto en el QA de D4 (2026-08-19), revisado el 2026-08-21:** el
**reenvío SSH de gcloud** (`gcloud compute ssh -L`, `spawn_ssh_forward` en
`native/src/tunnel.rs`) usa las credenciales propias del CLI. Bajo la opción B eso deja
de ser una rotura silenciosa y pasa a ser el comportamiento declarado: forma parte de la
escotilla, y su sesión la mantiene el usuario. Lo que **sí** sigue siendo obligatorio es
que exista la ruta nativa equivalente (SP-2), porque el reenvío es la única vía a los
puertos que la regla IAP no abre, y esa vía no puede depender de una escotilla.
Ya se observó el fallo con las credenciales caducadas: `gcloud compute ssh` aborta
con *"Reauthentication failed. cannot prompt during non-interactive execution"* y el
puerto local nunca escucha.

Importa porque el reenvío SSH es **la única vía a los puertos que la regla IAP no
abre** (8443, 3000 …), que son los de uso diario. El sustituto existe —
`native/src/ssh_forward.rs`, ssh2 nativo— pero sigue detrás de
`LCC_SSH_FORWARD_ENGINE=native` y marcado como experimental. **D5 no puede cerrar
sin promoverlo o sin decidir explícitamente que se pierde esa capacidad.**

Defecto menor asociado, que muere con la ruta: `api::start_ssh_forward` aplana
*cualquier* fallo a `protocol_error`, así que un problema de credenciales del CLI
se le presenta al usuario como "Respuesta inesperada del relay de IAP" — la misma
ambigüedad que tenía `relay_unreachable` antes del barrido. Si la ruta sobrevive,
clasificar esos fallos vuelve a ser trabajo pendiente.

**Evidencia exigida:** ese corte se ejecuta con `gcloud` **fuera del `PATH`** (o renombrado), no en la máquina de desarrollo tal cual. D3 pareció completo hasta que se descubrió que su camino nativo era inalcanzable sin el fichero ADC — invisible aquí precisamente porque esta máquina lo tiene. Ejecutar la matriz en el entorno hostil **es** el criterio de corte, no una comprobación adicional.

## Secuencia

```
D0 (externo, en paralelo)
D1 ─► D2 ─► D3 ─► D4 ─► D5   (+ luego SG-E: limpieza final)
```
D1 y D2 son independientes entre sí (podrían solaparse), pero D3 los necesita a ambos. D5 solo cierra tras D3+D4.

## Riesgos y mitigaciones

- **Reauth/RAPT:** mitigado por el patrón IAP Desktop (re-login interactivo). Se valida en D3 con una cuenta Workspace real.
- **Regresión de auth (crítica):** D3 va **detrás de flag**; gcloud sigue disponible hasta D5.
- **Verificación OAuth:** afecta a la distribución, no al diseño; decisión de D0.
- **Sin gcloud, no hay red de seguridad:** por eso D5 va al final y su QA es "máquina sin gcloud".

## Siguiente paso

Diseñar **D1** (núcleo OAuth) por el ciclo normal brainstorm → spec → plan → SDD.
