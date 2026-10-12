# auth_status sabe si la credencial se puede leer

Fecha: 2026-09-30 · Rama: 27H1-Preview · Estado: diseño aprobado, pendiente de revisar la spec

## Problema

Con el motor nativo, `accounts::auth_status()` da `authenticated = true` cuando el índice de cuentas
tiene una cuenta activa (`token_store::active_account()`, que es `load_index().active`). No lee el
llavero. La app confunde dos preguntas:

1. ¿Hay una cuenta configurada? Esto lo contesta el índice.
2. ¿Puedo usar su credencial ahora? Esto lo contesta el llavero.

`auth_status` contesta la 1 y toda la app la usa como si fuera la 2. Con el llavero caído (QA del
usuario, `DBUS_SESSION_BUS_ADDRESS` roto) la app se cree autenticada:

- `MultiProjectNotifier` refresca al arrancar: 10 listados de instancias que fallan.
- `projectsProvider` pasa su guard y llama a `listProjects`, que falla. Riverpod 3.3.2 lo reintenta
  con `defaultRetry`: 200 ms × 2ⁿ, tope 6,4 s, 10 reintentos. Son 11 intentos en 38,2 s.
- Después, un intento cada 5 minutos para siempre: el `Timer` de 5 min hace `invalidateSelf()` sin
  reiniciar el contador.
- El usuario ve una sesión iniciada que no puede hacer nada.

## Mediciones que fijan el diseño

| Qué | Resultado |
|---|---|
| Secuencia de llamadas, fake_async, misma forma que `projectsProvider` | 0 / 0,2 / 0,6 / 1,4 / 3,0 / 6,2 / 12,6 / 19,0 / 25,4 / 31,8 / 38,2 s; luego 338,2 s y 638,2 s. Coincide con el log real |
| `invalidate(gcloudStatusProvider)` tras agotar reintentos | 11 intentos nuevos: rearma el contador |
| `invalidate(projectsProvider)` / `refresh(projectsProvider)` | 1 intento, sin reintentos |
| Error de `api::list_projects()` sin Secret Service | `…keyring is unavailable…: Platform secure storage failure: no secret service provider or dbus session found`, en 0,03 s y sin red |
| Leer la entrada real, llavero sano | `Ok`, unos 69 ms (sonda: 68–70 ms) |
| Leer la entrada real, llavero bloqueado y diálogo cancelado | `NoStorageAccess` ("SS error: prompt dismissed"), 1,9 s |
| Leer la entrada real, llavero bloqueado y diálogo sin contestar | La lectura espera; se cortó a los 180 s |
| Leer la entrada real, llavero bloqueado y desbloqueado | `Ok` |
| Llamadas a `auth_status` | Dos, ambas por evento: construcción de `gcloudStatusProvider` y arranque de `MultiProjectNotifier` |

keyring 3.6.3 (`secret_service.rs::decode_error`) convierte `Locked`, `Prompt` y `NoResult` en
`NoStorageAccess`, y todo lo demás en `PlatformFailure`. Las mediciones lo confirman para los dos
casos que importan.

## Diseño

### Rust

- `token_store`: una función pura `classify_credential(Result<String, keyring::Error>) -> CredentialState`:
  - `Ok(_)` → `Readable`. El valor se suelta al momento y nunca se registra en el log.
  - `NoEntry` → `Missing`.
  - `PlatformFailure` → `Unreachable`.
  - `NoStorageAccess` → `Refused`.
  - Cualquier otro error → `Unclear`.
- `credential_state_within(email, plazo)` es la que usa `auth_status`. Si la lectura no contesta en
  `CREDENTIAL_READ_TIMEOUT` (3 s), devuelve `Pending`. Ver "El plazo" más abajo.
- `credential_state(email)` lee la entrada **real** de la cuenta, no la clave de sonda. "Backend
  arriba pero esta entrada ha desaparecido" también es permanente, y la sonda lo daría por sano.
- `keyring_backend_error` separa las dos variantes. Hoy ambas dicen "no Secret Service is running",
  y eso es falso con el llavero bloqueado:
  - `PlatformFailure`: "could not be reached … usually no Secret Service (GNOME Keyring or KWallet)
    is running".
  - `NoStorageAccess`: "refused access: it is locked, or the unlock was cancelled".
- `AuthStatus` gana `keyring_problem: Option<KeyringProblem>`, con `KeyringProblem { Unreachable, Refused, Pending }`.
  Con el motor gcloud siempre es `None`.
- `auth_status_for` (pura) recibe el estado de la credencial:

  | Motor | Cuenta activa | Credencial | authenticated | keyring_problem |
  |---|---|---|---|---|
  | gcloud | — | — | como hoy | None |
  | nativo | no | — | false | None |
  | nativo | sí | Readable | true | None |
  | nativo | sí | Missing | false | None |
  | nativo | sí | Unreachable | false | Unreachable |
  | nativo | sí | Refused | false | Refused |
  | nativo | sí | Pending (plazo agotado) | false | Pending |
  | nativo | sí | Unclear | true | None |

  `Unclear` se queda en el comportamiento de hoy. Lo que no sabemos clasificar no enseña una pantalla
  de llavero que podría ser falsa.

### El plazo (corrección de la primera versión)

La primera versión decía que esperar a un diálogo abierto "adelanta la espera de hoy, no la crea".
Era falso. El cuerpo entero del panel cuelga de `gcloudStatusProvider`
(`main.dart:625`, `loading: () => CircularProgressIndicator()`). Hoy `auth_status` resuelve rápido
y solo el área de proyectos espera a `listProjects`. Si `auth_status` esperase al diálogo, toda la
app sería una rueda girando, sin explicación ni salida, mientras el diálogo siga abierto (medido:
más de 180 s si nadie lo contesta).

Por eso la lectura tiene plazo: `CREDENTIAL_READ_TIMEOUT = 3 s`.

- **Por qué 3 s.** La máquina contesta en 69 ms (sano) y en menos de 1 ms (caído). 3 s es unas 40
  veces lo sano y deja margen para que el servicio arranque en frío por activación D-Bus (esto es
  una estimación, no una medida). Pasado ese tiempo, quien falta por contestar es una persona.
- **Por qué no más.** Si el plazo es corto, a quien está tecleando la contraseña se le muestra
  "esperando a que desbloquees", que es exactamente lo que está pasando, y al terminar pulsa
  Comprobar de nuevo. Si es largo, la app entera se queda en blanco sin decir nada durante todo ese
  tiempo. El error barato es el primero.
- **La lectura no se cancela al agotar el plazo.** Sigue esperando en su hilo, y el diálogo sigue
  abierto y se puede contestar.
- **Una sola lectura en curso por cuenta.** Si ya hay una lectura esperando para esa cuenta,
  `credential_state_within` se engancha a ella en vez de lanzar otra. Pulsar Comprobar de nuevo
  con el diálogo abierto, quizá detrás de la ventana, no apila diálogos: no sabemos cómo trata
  gnome-keyring varios desbloqueos a la vez, y así no hace falta saberlo. Cuando el usuario
  desbloquea, la lectura en curso termina con `Readable` y la siguiente comprobación lo ve al
  instante.

### Puente

`AuthStatus` y el enum nuevo cruzan el puente. Lo regenera esta sesión. Añadir un campo **no**
cambia el content hash de frb (ver la memoria "content hash de frb"), así que un `.so` de un lado y
el Dart del otro no avisarían: se reconstruyen los dos juntos y se entregan los dos hashes.

### Dart

- `gcloudStatusProvider` añade `'keyringUnreachable'`, `'keyringRefused'` y `'keyringPending'` al mapa.
- `DashboardScreen`: una rama nueva **antes** de la de "no autenticado", con la misma forma que la
  pantalla de "falta gcloud". Tiene:
  - un título;
  - un texto según el caso:
    - *Unreachable*: no se puede contactar con el llavero del sistema; suele significar que GNOME
      Keyring o KWallet no está en marcha.
    - *Refused*: el llavero no dio acceso; está bloqueado o se canceló el desbloqueo.
    - *Pending*: esperando a que desbloquees el llavero; si hay un diálogo pidiendo la contraseña
      (puede estar detrás de esta ventana), contéstalo y pulsa Comprobar de nuevo.
  - una línea común: la sesión sigue guardada y no hace falta volver a iniciar sesión;
  - el botón **Comprobar de nuevo** (`dashboardCheckAgainButton`, que ya existe). Invalida
    `gcloudStatusProvider` y `multiProjectProvider`. Por la medición, invalidar el estado rearma los
    reintentos, así que no hace falta reiniciar la app.
- No se manda a iniciar sesión: con el llavero inaccesible tampoco se podría guardar la credencial,
  y la sesión sigue intacta.
- Todo lo demás se detiene solo porque ya depende de `authenticated`: el guard de `projectsProvider`,
  el refresco al arrancar de `MultiProjectNotifier` y el chip de cuenta.
- l10n EN+ES: título, tres textos, la línea común.

## Fuera de alcance, y por qué

- `retry:` en `projectsProvider` e `instancesProvider`. Tras el arreglo no se llaman con el llavero
  inaccesible al arrancar. Queda un residuo: si el llavero cae **a mitad de sesión**, reintentan como
  hoy. Clasificarlo bien pide un error tipado en `list_projects`.
- Un refresco manual de `projectsProvider` tras agotar reintentos hace un único intento (medición
  B/C). Es un defecto que ya existía, independiente del llavero.

## Tests

- Rust:
  - tabla de `classify_credential`: las cinco salidas, con errores keyring construidos;
  - tabla de `auth_status_for`: la de arriba;
  - plazo y lectura única, con un lector inyectado que se queda bloqueado hasta que el test lo
    suelta: da `Pending` al agotar el plazo; una segunda llamada durante la espera no lanza otra
    lectura; y cuando el lector contesta, la llamada siguiente devuelve su resultado;
  - el texto de `keyring_backend_error` para cada variante (que "locked" no diga "not running");
  - mutaciones sobre las tres.
- Dart:
  - test de widget de `DashboardScreen` con `gcloudStatusProvider` sobrescrito: cada problema
    muestra su pantalla y **no** la de iniciar sesión, y el botón invalida el estado;
  - la pantalla nueva entra en `es_overflow_test` (720/1280).
- QA real, repitiendo las mediciones anteriores con la build:
  - bus roto: pantalla *Unreachable* y 0 "Listing GCP projects" en el log;
  - llavero bloqueado y diálogo sin tocar: a los 3 s, pantalla *Pending* con la app usable; al
    desbloquear y pulsar Comprobar de nuevo, entra;
  - llavero bloqueado y diálogo cancelado: pantalla *Refused*; "Comprobar de nuevo" vuelve a pedir
    la contraseña y, al desbloquear, carga los proyectos sin reiniciar.
