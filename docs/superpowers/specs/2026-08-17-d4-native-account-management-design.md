# D4 — Gestión de cuentas nativa (spec de diseño)

**Fecha:** 2026-08-17
**Rama:** `27H1-Preview`
**Sub-proyecto:** D4 de **SG-D**, dentro de la iniciativa de salida de `gcloud`
**Depende de:** D1 (núcleo OAuth) ✔, D2 (almacén de tokens) ✔, D3 (adquisición nativa de token) ✔
**Roadmaps:** [SG-D](2026-08-12-sgd-oauth-roadmap.md) · [salida de gcloud](2026-08-12-gcloud-removal-roadmap.md)

## Objetivo

Reimplementar list / switch / add / remove de cuentas sobre el almacén nativo
(`native/src/token_store.rs`) en vez de sobre el CLI de `gcloud`, y hacer que
`list_projects_for_account` use REST con el token de esa cuenta.

**El interfaz Dart no cambia.** `AccountNotifier`, `accountProvider` y los
nombres del bridge se mantienen tal cual para no rehacer la UI. Los nombres
siguen diciendo "gcloud" aunque ya no lo invoquen: renombrarlos es limpieza de
SG-E, no de D4.

Todo va **detrás del flag `LCC_AUTH_ENGINE=native`** que introdujo D3. Con el
flag ausente o distinto de `native`, el comportamiento es idéntico al actual:
`gcloud` sigue siendo el motor por defecto hasta D5.

## Criterio de corte

El diálogo de cuentas lista, cambia, añade y quita cuentas contra el almacén
nativo, sin invocar `gcloud`, en una máquina donde `gcloud` no está en el
`PATH`. Ver **Evidencia exigida** más abajo: el criterio no se da por cumplido
con una impresión de pantalla.

## Decisiones tomadas (y por qué)

### La guarda de estado entra en D4, no en D5

`AccountNotifier.build()` solo carga cuentas si `gcloudStatusProvider` dice
`authenticated: true`, y ese provider **cortocircuita en `installed: false`**:

```dart
final installed = await checkGcloudInstalled();
if (!installed) return {'installed': false, 'authenticated': false};
```

Sin gcloud instalado, el diálogo de cuentas nunca pide la lista, por muy nativo
que sea el almacén detrás. Es la misma forma que el defecto de D3 —una guarda
lejos de la función que se edita, invisible en la máquina de desarrollo porque
aquí gcloud sí está— y choca de frente con la evidencia que este mismo
sub-proyecto debe producir. Por tanto la guarda se arregla **aquí**.

### `remove` revoca en Google

`gcloud auth revoke <email>` invalida el refresh token **en Google**. Sustituirlo
por un borrado local dejaría el refresh token válido indefinidamente: una
regresión de seguridad silenciosa respecto a lo que hace hoy la app. D4 revoca
y después borra.

### Añadir una cuenta no cambia la activa

Hoy, en la ruta gcloud, `auth login` deja activa la cuenta nueva — pero
`addAccount()` en Dart solo llama a `refresh()`, así que **la coreografía de
aislamiento no se ejecuta**: `switchAccount()` es quien desconecta túneles,
guarda la selección de proyectos de la cuenta anterior y limpia la instancia
seleccionada. Añadir se lo salta. Es un agujero que ya existe.

En nativo, `token_store::save_account` fija la activa **solo si no había
ninguna**, y ese es el comportamiento que se conserva: el primer login sí deja
la cuenta activa; con una activa ya presente, la nueva entra en la lista y el
usuario cambia explícitamente, lo que sí dispara el aislamiento completo. Cuesta
un clic más y elimina el agujero en lugar de copiarlo.

### Fachada, no trait

Un módulo `accounts.rs` concentra el despacho por motor y la implementación
nativa. La alternativa —un `trait AccountBackend` con dos implementaciones— sería
andamiaje para exactamente dos casos, uno de los cuales está programado para
morir en D5. La otra alternativa —bifurcar dentro de cada wrapper de `api.rs`—
dispersa la lógica en seis sitios de un fichero que ya es un cajón de wrappers,
y obliga a desmontar seis `match` en D5.

## Arquitectura

```
Dart: AccountNotifier / accountProvider      (sin cambios de interfaz)
          │
          ▼
bridge: list_gcloud_accounts, switch_gcloud_account, add_gcloud_account,
        remove_gcloud_account, list_projects_for_account,
        get_gcloud_account_email, check_auth_status
          │   (api.rs: wrappers de una línea)
          ▼
native/src/accounts.rs        ← match auth_engine()
     ├── AuthEngine::Gcloud  → crate::gcloud::*        (lo de hoy, intacto)
     └── AuthEngine::Native  → token_store + oauth + gcp_rest_client
```

### Superficie de `native/src/accounts.rs`

```rust
pub async fn list() -> Result<Vec<GcloudAccount>>
pub async fn switch(email: &str) -> Result<()>
pub async fn add() -> Result<()>
pub async fn remove(email: &str) -> Result<()>
pub async fn active_email() -> Result<String>
pub async fn projects_for(email: &str) -> Result<Vec<GcpProject>>
pub async fn auth_status() -> AuthStatus
```

`AuthStatus { gcloud_installed: bool, authenticated: bool }` es tipo nuevo que
cruza el bridge.

`GcloudAccount { account: String, status: String }` **no cambia**: el Dart
distingue la activa por `status == 'ACTIVE'`.

Los wrappers de `api.rs` conservan nombre y firma. `add_gcloud_account` pasa de
`fn` a `async fn` en Rust; el call site Dart (`await addGcloudAccount()`) no
cambia, porque el bridge devuelve `Future` en ambos casos.

## Las operaciones en modo nativo

| Operación | Implementación |
|---|---|
| `list` | `token_store::list_accounts()` + `active_account()`, mapeado a `GcloudAccount` con `status = "ACTIVE"` en la activa y `""` en el resto. Orden: el del índice. |
| `switch` | `token_store::set_active_account(email)` (falla si la cuenta es desconocida, dejando la activa anterior intacta) + `gcp_rest_client::invalidate_cached_access_token()`. |
| `add` | `oauth::sign_in_and_store()`, descartando el email devuelto. No cambia la activa salvo que no hubiera ninguna. |
| `remove` | Cargar el refresh token → `oauth::revoke_refresh_token()` → `token_store::delete_account()`. |
| `active_email` | `token_store::active_account()`, o error con el literal `"No active GCP account"`. |
| `projects_for` | REST con un token acuñado del refresh token de esa cuenta (ver abajo). |

**Toda llamada a `token_store` va por `oauth::store_call`** (spawn_blocking).
zbus conduce su propio runtime con `block_on` y entra en pánico si se le invoca
desde un worker de tokio; es la trampa que ya documentó D2.

### `remove`: el borrado local no depende de la revocación

El orden es revocar y luego borrar, pero **el borrado ocurre igualmente si la
revocación falla** (sin red, token ya caducado, cuenta borrada en Google). El
fallo se registra en el log. Dejar la entrada local colgando porque Google no
contestó sería el peor de los dos resultados: el usuario ve una cuenta que ya no
funciona y no tiene forma de quitarla.

Si la cuenta borrada era la activa, el índice queda sin activa —`index_remove`
ya lo hace—, que es exactamente lo que deja `gcloud auth revoke` hoy.

### `active_email`: el literal importa

El error debe contener `"No active GCP account"` porque `classifyRustError`
(`lib/src/features/app_error.dart`) ya lo mapea a `AppErrorCode.notAuthenticated`.
Cambiar la redacción rompería la clasificación sin que ningún test lo note.

### Nuevo en `oauth.rs`

```rust
pub async fn revoke_refresh_token(refresh_token: &str) -> Result<()>
```

`POST https://oauth2.googleapis.com/revoke` con `token=<refresh_token>`
form-encoded. El token **nunca** se registra; el cuerpo de una respuesta de error
pasa por `crate::redact::redact_sensitive` antes de llegar al log o al mensaje.

## El token de una cuenta que no es la activa

`ResourceManagerClient::list_projects()` obtiene el token de `self.auth`, que es
el de la cuenta activa, y su caché (`TOKEN_CACHE`) pertenece a esa cuenta. Listar
proyectos de otra cuenta con ese cliente devolvería los proyectos equivocados.

La parte HTTP + parseo de `list_projects()` se extrae a una función libre de
`gcp_rest_client.rs`:

```rust
async fn fetch_projects(client: &reqwest::Client, token: &str) -> Result<Vec<GcpProject>>
```

y la llaman las dos rutas:

- `ResourceManagerClient::list_projects()` con `self.auth.get_access_token()` —
  comportamiento idéntico al actual, mismo parser;
- `accounts::projects_for(email)` con un token refrescado del refresh token de
  esa cuenta, **sin tocar `TOKEN_CACHE`**.

Un `RefreshOutcome::NeedsReauth` se traduce a un error cuyo texto contiene
`invalid_grant`, que el banner de sesión (`GcpSessionBanner`) ya reconoce y
convierte en oferta de re-login.

## La guarda de estado

`gcloudStatusProvider` pasa a una única llamada al bridge:

```rust
pub async fn check_auth_status() -> AuthStatus
```

- **Motor gcloud:** exactamente lo de hoy — `gcloud_installed = is_gcloud_installed()`,
  y `authenticated = is_gcloud_authenticated()` solo si está instalado.
- **Motor nativo:** `gcloud_installed` sigue reportando la verdad sobre gcloud
  (Doctor y la fila de dependencias la consultan y no pueden empezar a mentir),
  pero `authenticated = token_store::active_account().is_some()` y **no está
  condicionado a que gcloud exista**.

El Dart conserva su mapa `{'installed': …, 'authenticated': …}` para no tocar a
los consumidores del provider; solo cambia de dónde lo saca.
`checkGcloudInstalled` / `checkGcloudAuth` siguen existiendo para Doctor.

## Errores e i18n

Sin claves nuevas. Todo lo que sale de aquí cae en la taxonomía existente vía
`classifyRustError` (`notAuthenticated`, `permissionDenied`, `network`), y el
banner de reauth ya existe. Si alguna redacción nueva tuviera que verse en
pantalla, sería una clave en `app_en.arb` **y** `app_es.arb` con paridad, más
`flutter gen-l10n`; el diseño no lo necesita.

## Pruebas

**Unitarias, sin red ni keyring:**

- **el mapeo**, extraído como función pura para poder probarlo sin keyring:

  ```rust
  fn to_accounts(emails: Vec<String>, active: Option<String>) -> Vec<GcloudAccount>
  ```

  Casos: con cuenta activa (exactamente una lleva `"ACTIVE"`), sin ninguna
  activa (ninguna la lleva), lista vacía, y una `active` que no está en la lista
  (no debe inventar una entrada).

- **la guarda del despacho**, también pura:

  ```rust
  enum Route { Gcloud, Native }
  fn route(engine: AuthEngine) -> Route
  ```

  Toda operación pública de `accounts.rs` decide con `route(oauth::auth_engine())`
  y con nada más. El test la ejercita en los dos sentidos. Es lo que falla si
  alguien cablea un brazo o se deja una operación sin despachar; el propio test
  no basta para esto último, así que se acompaña de un `grep` en la revisión:
  ninguna función pública de `accounts.rs` llama a `crate::gcloud::` fuera del
  brazo `Route::Gcloud`.

- `accounts::switch` a una cuenta desconocida **propaga** el error en vez de
  tragárselo, dejando la activa anterior intacta (`token_store` ya cubre la
  invariante en `set_active_requires_a_known_account`).

**Lo que las unitarias no pueden probar:** que la lista mostrada procede del
almacén nativo. Eso es una afirmación de divergencia entre dos fuentes y va en
QA manual.

## Evidencia exigida

Vinculante por el [estándar de verificación](2026-08-12-gcloud-removal-roadmap.md#estándar-de-verificación-obligatorio-para-d4-d5-y-sg-e).
Con `LCC_AUTH_ENGINE=native`:

1. **Divergencia en los dos sentidos.** Una cuenta presente en `gcloud auth list`
   y ausente del almacén nativo **no** aparece en el diálogo. Una presente en el
   almacén y ausente de gcloud **sí** aparece.
2. **Las tres fuentes a la vez**, en el mismo momento: la salida de
   `gcloud auth list`, el contenido de `oauth_accounts.json`, y la lista en
   pantalla. **Si las tres coinciden, la prueba no vale**: en esta iniciativa la
   UI ya mostró una vez la cuenta corporativa de gcloud mientras el token era de
   una cuenta personal del almacén nativo, y coincidieron por azar.
3. **Entorno hostil.** La matriz completa se repite con `gcloud` fuera del
   `PATH`. Sin eso, la guarda de estado no está verificada — y es precisamente la
   pieza cuyo fallo sería invisible en esta máquina.
4. **Revocación comprobada.** Tras `remove`, el refresh token revocado ya no
   sirve: un intento de refresco con él devuelve `invalid_grant`.

## Fuera de alcance

- Renombrar los símbolos del bridge que dicen "gcloud" y ya no lo invocan
  (SG-E).
- Retirar `execute_login` / `execute_logout` y las funciones de cuenta de
  `gcloud.rs` (D5).
- Cambios en la UI del diálogo de cuentas. El interfaz Dart se mantiene estable
  a propósito.
- La decisión pendiente sobre `x-goog-user-project` y la cuota.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Regresión de auth al tocar el status | Todo detrás del flag; con el flag apagado la ruta es byte a byte la de hoy. |
| La regeneración del bridge rompe call sites | Cautela conocida: revisar `gcloud_provider.dart` y `manual_instance_dialog.dart` tras regenerar. |
| `projects_for` sirviendo los proyectos de la cuenta equivocada | Es el fallo silencioso más probable del sub-proyecto. Por eso el token nunca sale de `TOKEN_CACHE` y la evidencia exige divergencia, no coincidencia. |
| Pánico de zbus desde un worker de tokio | Toda llamada a `token_store` pasa por `store_call`. |
