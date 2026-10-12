# Diseño: SG-D / D2 — almacén de tokens en el keyring del sistema

**Fecha:** 2026-08-13
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Módulo Rust nuevo, autocontenido (sin bridge, sin Dart). Segunda pieza de **SG-D** — ver `docs/superpowers/specs/2026-08-12-gcloud-removal-roadmap.md`.

## Objetivo

Persistir de forma segura el `refresh_token` que D1 obtiene, por cuenta, para que la sesión sobreviva al cierre de la app. Es lo que convierte el login de D1 en una sesión reutilizable y lo que D3 (adquisición de token) y D4 (gestión de cuentas) consumirán.

D2 entrega **solo el almacén**: un módulo con API clara, tests unitarios reales y ningún consumidor todavía. Sin bridge (nada de regen) y sin tocar la app.

## Contexto

- **D1 está hecho y validado en vivo** (build `20260803.19`): `native/src/oauth.rs::interactive_login()` devuelve `OAuthTokens { email, refresh_token, access_token, expires_in_secs }`. Dos logins consecutivos reales devolvieron `refresh token: received`, así que hay token que guardar y `prompt=consent` garantiza que lo siga habiendo en logins posteriores.
- **El repo ya tiene el patrón exacto** en `native/src/windows_credentials/storage.rs`: `keyring::Entry::new(SERVICE_NAME, &key)` + `set_password(json)` / `get_password()` / `delete_credential()`, con `keyring::Error::NoEntry` para "no existe", y un **fichero índice** aparte porque *la API del keyring no permite enumerar*. El índice vive en `app_dirs::migrated_app_dir(dirs::data_local_dir()?)`. Ese módulo también **auto-sana** entradas presentes en el índice pero ausentes del keyring.
- `keyring = "3"` ya es dependencia; **D2 no añade ninguna**.
- Precedente de tests del repo: tests puros normales + un `#[test] #[ignore] // Requires system keyring` para el round-trip real.
- En Linux el keyring necesita un **Secret Service** vivo (GNOME Keyring / KWallet). En SSH, headless o contenedores mínimos no existe.

## Decisiones

| Decisión | Elección |
|---|---|
| Alcance | Módulo Rust autocontenido + tests. **Sin bridge, sin regen, sin Dart, sin consumidores.** |
| Qué se persiste | Solo `email` + `refresh_token` (+ fecha de alta). **El access token NO se persiste**: dura ~1 h y se re-deriva; `gcp_rest_client` ya lo cachea en memoria. |
| Keyring no disponible | **Fallo con error claro y accionable.** Nunca se escribe un token de larga vida en disco en claro. Sin persistencia, la sesión dura lo que el proceso. |
| Servicio del keyring | Reutilizar `SERVICE_NAME = "linux-cloud-connector"` (el que ya usa el repo), con prefijo de clave propio `oauth::<email>` para no colisionar con las credenciales de Windows. |
| Índice | Fichero JSON propio (`oauth_accounts.json`) con la lista de emails **y** cuál es la cuenta activa. **Nunca contiene secretos.** |
| Factorización | La lógica del índice se implementa como **funciones puras** sobre un valor `AccountIndex`, con capas finas de E/S encima → tests reales sin tocar disco ni keyring. |
| Dependencias nuevas | **Ninguna.** |

## Diseño

### 1. Módulo `native/src/token_store.rs` (`pub mod token_store;` en `lib.rs`)

Tipos:

```rust
/// Lo que se guarda en el keyring, por cuenta. `refresh_token` es secreto.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredAccount {
    pub email: String,
    pub refresh_token: String,
    /// RFC 3339, por consistencia FFI con el resto del repo.
    pub added_at: String,
}

/// Índice en disco. SOLO emails — jamás un secreto.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
struct AccountIndex {
    accounts: Vec<String>,
    active: Option<String>,
}
```

API pública (lo que consumirán D3 y D4). `Result` es **`anyhow::Result`**, como en `oauth.rs` — no el `Result<_, String>` del módulo de credenciales de Windows, que es un patrón más viejo del repo:

```rust
pub fn save_account(email: &str, refresh_token: &str) -> anyhow::Result<()>;
pub fn load_refresh_token(email: &str) -> anyhow::Result<String>;
pub fn list_accounts() -> Vec<String>;
pub fn delete_account(email: &str) -> anyhow::Result<()>;
pub fn active_account() -> Option<String>;
pub fn set_active_account(email: &str) -> anyhow::Result<()>;
```

**Primera cuenta = cuenta activa:** `save_account` marca la cuenta como activa **si no había ninguna activa**. Sin esta regla, tras el primer login no habría cuenta activa y D4 tendría que inventarse el criterio. Guardar una cuenta cuando ya hay otra activa **no** cambia la activa.

### 2. Dónde vive cada cosa

- **Secreto** → keyring del sistema: `Entry::new("linux-cloud-connector", &format!("oauth::{}", email))`, valor = JSON de `StoredAccount`.
- **Índice** → `app_dirs::migrated_app_dir(dirs::data_local_dir()?)` + `oauth_accounts.json`, contenido = `AccountIndex`.

La separación es deliberada: el keyring no enumera, así que el índice existe para poder listar cuentas y recordar la activa **sin** que ningún secreto toque el disco.

### 3. Operaciones puras sobre el índice (el corazón testeable)

```rust
fn index_upsert(index: &mut AccountIndex, email: &str);   // idempotente, sin duplicados
fn index_remove(index: &mut AccountIndex, email: &str);   // limpia `active` si apuntaba ahí
fn index_set_active(index: &mut AccountIndex, email: &str) -> Result<()>; // error si no está en accounts
fn keyring_key(email: &str) -> String;                    // "oauth::<email>"
```

Encima, capas finas: `load_index()` / `save_index()` hacen la E/S y nada más.

### 4. Consistencia entre keyring e índice

Son dos almacenes distintos, así que el orden importa:

- **Guardar:** primero el keyring, **después** el índice. Si el índice falla, se intenta borrar la entrada del keyring (rollback de mejor esfuerzo) y se devuelve el error, para no dejar un secreto huérfano e invisible.
- **Borrar:** se quita del keyring y del índice; `NoEntry` se tolera (ya no estaba). Si apuntaba a la cuenta activa, `active` queda a `None`.
- **Auto-sanado:** `list_accounts()` poda del índice los emails cuya entrada de keyring ya no existe (mismo comportamiento que `windows_credentials/storage.rs`), y si la activa era una de esas, la limpia.

### 5. Errores

Tres casos distinguibles, todos en inglés (capa Rust; su localización llegará cuando D4 los exponga por el bridge):

- **Keyring no disponible** (no hay Secret Service): error explícito indicando que la sesión no puede persistirse y que habrá que iniciar sesión en cada arranque — no un "no encontrado" genérico.
- **Cuenta no almacenada** (`keyring::Error::NoEntry`): "no hay sesión guardada para `<email>`".
- **Índice ilegible/corrupto**: se trata como índice vacío (mismo criterio que el módulo existente), sin abortar; los secretos del keyring siguen intactos y se recuperan al volver a guardar.

**Concurrencia:** dos procesos de LCC escribiendo el índice a la vez pueden pisarse (último gana). Se acepta explícitamente — la app es de escritorio y de instancia única en la práctica; el keyring, que guarda lo importante, es atómico por entrada. No se añade bloqueo de fichero.

## Testing

Tests unitarios **reales**, sin red, sin navegador y sin keyring (esta es la primera pieza de SG-D que se puede probar así de verdad):

- `keyring_key` produce `oauth::<email>`.
- `index_upsert` añade y es **idempotente** (dos veces no duplica).
- `index_upsert` marca la primera cuenta como activa, y **no** cambia la activa al añadir una segunda.
- `index_remove` quita la cuenta **y** limpia `active` si apuntaba a ella; deja `active` intacta si no.
- `index_set_active` funciona con una cuenta presente y **falla** con una ausente.
- Round-trip de serialización de `AccountIndex` (incluido el caso `active: None`).
- **El índice serializado no contiene el secreto**: se serializa un índice tras registrar una cuenta cuyo refresh token es una cadena reconocible y se asierta que esa cadena **no** aparece en el JSON. Es la propiedad de seguridad central del diseño, y queda fijada por un test.
- `StoredAccount` round-trip JSON.

Además, siguiendo el precedente del repo, un `#[test] #[ignore] // Requires system keyring` que haga `save_account` → `load_refresh_token` → `delete_account` contra el keyring real.

Verificación: `cargo test` verde, `cargo build --release` limpio sin warnings nuevos, `flutter test` intacto (D2 no toca Dart).

## Alcance / fuera de alcance

- **Dentro:** `native/src/token_store.rs` con la API pública, las operaciones puras del índice, el manejo de los tres errores, el auto-sanado, `pub mod token_store;` en `lib.rs`, y los tests.
- **Fuera:** usar el almacén para obtener/refrescar tokens (**D3**); gestión de cuentas, bridge y UI (**D4**); retirada de gcloud y migración de las cuentas que hoy gestiona gcloud (**D5**); cifrado propio más allá del que da el keyring del SO; bloqueo entre procesos; fallback a fichero cuando no hay keyring (descartado por decisión de seguridad).

## Verificación

- `cargo test` verde incluyendo los tests puros nuevos; el `#[ignore]` pasa a mano en una máquina con keyring.
- `cargo build --release` sin warnings nuevos; `flutter test` verde.
- Ningún camino escribe el `refresh_token` fuera del keyring — fijado por el test del índice sin secretos.
- Sin dependencias nuevas y sin cambios en el bridge.
