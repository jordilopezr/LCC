# auth_status comprueba que Google acepta la sesión

Fecha: 2026-10-01 · Rama: 27H1-Preview · Estado: diseño aprobado (enfoque A), pendiente de revisar la spec
Sigue a: `2026-09-30-auth-status-keyring-design.md` (el llavero) y al commit 981761f (sin reintentos para `notAuthenticated`).

## Problema

Desde la .43, con el motor nativo, `auth_status` da `authenticated = true` cuando la credencial de la
cuenta activa **se lee** del llavero. Que se lea no significa que Google la acepte. En la QA del
2026-10-01, tras desbloquear el llavero, Google rechazó el refresh token (`invalid_grant`). La app se
creía autenticada, mostraba el panel y fallaban todos los listados. El usuario tuvo que deducir que
había que volver a iniciar sesión.

`auth_status` contesta "la leo"; la app lo entiende como "sirve".

## Lo que ya existe y se conserva

- `GcpSessionBanner` (`main.dart:473`): aviso de "sesión caducada" con un botón para volver a iniciar
  sesión. Aparece cuando `projectsProvider` o `instancesProvider` fallan con `notAuthenticated`.
  Desde 981761f ese fallo no se reintenta, así que el aviso debería aparecer al primer fallo. Cubre
  la sesión que caduca **con la app abierta**, que la comprobación al arrancar no puede ver. No se
  toca; se verifica en la QA.
- `oauth::refresh_access_token` ya distingue tres salidas: `RefreshOutcome::Token`,
  `RefreshOutcome::NeedsReauth` (`invalid_grant`, `rapt_required`, `invalid_rapt`) y `Err` (red, 5xx,
  timeout del cliente de 30 s, que su comentario declara transitorio).
- `TOKEN_CACHE` (`gcp_rest_client.rs`): token de acceso de 300 s, etiquetado por motor. El cerrojo se
  mantiene durante toda la obtención; los listados lo usan a través de
  `GcpAuthClient::get_access_token`.

## Mediciones (2026-10-01, desde esta máquina)

| Qué | Resultado |
|---|---|
| `refresh_access_token` con red, 5 veces seguidas | `Token` en 178 / 191 / 180 / 150 / 268 ms |
| Lo mismo dentro de `bwrap --unshare-net` (sin red) | `Err` ("Token refresh request failed: error sending request…") en unos 20 ms |
| Red que pierde paquetes | No medido: lo acota el timeout del cliente HTTP, 30 s |

## Diseño

### Rust: la comprobación (enfoque A)

- Un tipo nuevo en `gcp_rest_client`: `SessionCheck { Accepted, Rejected, Unverified }`.
- Una función pura `session_check_from(Result<RefreshOutcome>) -> SessionCheck`:
  - `Ok(Token)` → `Accepted`;
  - `Ok(NeedsReauth)` → `Rejected`;
  - `Err(_)` → `Unverified`.
- `check_native_session(plazo) -> SessionCheck`, todo bajo el mismo cerrojo de `TOKEN_CACHE` que usa
  `get_access_token`:
  - Si hay un token del motor nativo en la caché, dentro de su TTL, devuelve `Accepted`: Google lo
    emitió hace menos de 5 minutos.
  - Si no, carga el refresh token de la cuenta activa, hace el intercambio y lo clasifica con
    `session_check_from`. Con `Token`, **guarda el token en la caché**: los listados que vienen
    detrás lo reutilizan y no hay un segundo intercambio.
  - Todo bajo `tokio::time::timeout(plazo, …)`. Si se agota, devuelve `Unverified`. Al soltar el
    future se libera el cerrojo.
  - Un fallo al cargar el refresh token (no debería ocurrir, porque `auth_status` solo llega aquí si
    la credencial es `Readable`) también da `Unverified`.
- La parte de intercambio y clasificación se comparte con `token_from_native_session`, para que
  `get_access_token` y la comprobación no puedan discrepar. `get_access_token` sigue convirtiendo
  `NeedsReauth` en el error de siempre, con el marcador `(invalid_grant)`.

### Rust: `auth_status`

- `SESSION_CHECK_TIMEOUT = 2 s`.
- Con el motor nativo, **solo** si la credencial es `Readable`, se llama a
  `check_native_session(SESSION_CHECK_TIMEOUT)`. En cualquier otro estado del llavero no se pregunta
  a Google.
- `AuthStatus` gana `pub session_rejected: bool`. Con el motor gcloud siempre es `false`.
- `auth_status_for` (pura) recibe también el resultado de la comprobación:

  | Motor | Credencial (llavero) | Google | authenticated | keyring_problem | session_rejected |
  |---|---|---|---|---|---|
  | gcloud | — | — | como hoy | None | false |
  | nativo | sin cuenta | — | false | None | false |
  | nativo | Missing | — | false | None | false |
  | nativo | Unreachable / Refused / Pending | — | false | el que corresponda | false |
  | nativo | Readable | Accepted | true | None | false |
  | nativo | Readable | **Rejected** | **false** | None | **true** |
  | nativo | Readable | Unverified | true | None | false |
  | nativo | Unclear | — (no se pregunta) | true | None | false |

  `Unverified` y `Unclear` conservan la respuesta de hoy. Sin red no se puede saber si la sesión
  vale, y mandar a iniciar sesión sería afirmar algo que no se sabe. Si estaba muerta, el aviso lo
  dirá en cuanto falle el primer listado.

### El plazo de 2 s

- **Por qué 2 s.** La red sana contesta en 150–268 ms (medido); 2 s son unas 8 veces eso. Sin red,
  el fallo llega en unos 20 ms, sin esperar al plazo.
- **Qué cuesta cada error.**
  - Plazo agotado = `Unverified` = `authenticated` como hoy. Un plazo corto solo cuesta no detectar
    al arrancar una sesión muerta sobre una red lenta, y el aviso la detecta después.
  - Un plazo largo deja el panel entero esperando (`main.dart:625`), sin explicación.
  - El error barato es el primero.
- **Peor caso del arranque.** La comprobación de Google solo se hace si el llavero contestó
  `Readable` dentro de sus 3 s (`CREDENTIAL_READ_TIMEOUT`). El máximo teórico es casi 5 s: un
  llavero que contesta justo antes de su plazo más una red lenta que agota los 2 s. Con un diálogo
  de desbloqueo sin contestar la credencial queda `Pending` y a Google ni se le pregunta (3 s). El
  caso sano medido es unos 69 ms (llavero) + 150–268 ms (Google).

### Puente

`AuthStatus` gana un campo, así que hay que regenerar el puente. Por el punto ciego ya medido, el
content hash no cambiará: se reconstruyen los dos lados juntos y se entregan los dos hashes.

### Dart

- `statusMapFor` añade `'sessionRejected'`.
- `dashboardGateFor` no cambia de orden: `sessionRejected` implica `authenticated = false`, así que
  cae en `signIn`. El orden ya fijado (llavero antes que iniciar sesión) sigue valiendo, porque los
  dos estados no se dan a la vez.
- Rama `signIn` de `DashboardScreen`: si `status['sessionRejected'] == true`, encima del botón de
  iniciar sesión aparece una línea: "Tu sesión de Google ha caducado o se ha revocado; inicia sesión
  otra vez." El botón y su flujo no cambian. La línea sale de un widget pequeño y testeable
  (`SessionRejectedNote`), para no tener que montar `main.dart` en un test.
- l10n EN+ES: una clave nueva.

## Fuera de alcance

- Comprobar periódicamente con la app abierta. Ese caso lo cubre el aviso.
- El motor gcloud: su autenticación la decide `gcloud`.
- Cambiar el timeout de 30 s de `refresh_access_token` para los listados.

## Tests

- Rust:
  - tabla de `session_check_from` (las tres salidas);
  - tabla de `auth_status_for` (la de arriba, incluida la fila gcloud con `Rejected` de entrada, que
    no debe dar `session_rejected`);
  - `check_native_session` devuelve `Accepted` desde la caché sin intercambiar, y `Unverified`
    cuando se agota el plazo. Para no depender de la red, con el intercambio inyectado; mismo patrón
    que `InFlightReads` con su lector inyectado;
  - mutaciones sobre todo lo anterior.
- Dart:
  - `statusMapFor` con `sessionRejected`, ida y vuelta;
  - `dashboardGateFor`, que `sessionRejected` da `signIn`;
  - test de widget de `SessionRejectedNote`;
  - la nota entra en `es_overflow_test`.

## QA real

1. **Arranque sano:** el panel sale sin ninguna espera visible. En el log, un único intercambio de
   token antes del primer listado, no dos.
2. **Sin red** (`bwrap --unshare-net`, la app gráfica funciona por sockets de ruta): se ve el panel
   (`Unverified`), no la pantalla de iniciar sesión. Los listados fallan por red y NO sale el aviso
   de sesión caducada.
3. **Sesión rechazada:** **con el consentimiento del usuario**, revocar en Google el refresh token de
   LCC. Hay que volver a iniciar sesión después.
   - Al arrancar: pantalla de iniciar sesión con la línea de sesión caducada.
   - Con la app abierta (revocar después de arrancar y forzar un listado): el aviso de arriba sale al
     primer fallo, sin reintentos, y la lista de proyectos deja de intentarlo.
