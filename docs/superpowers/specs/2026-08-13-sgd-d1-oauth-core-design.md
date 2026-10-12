# Diseño: SG-D / D1 — núcleo OAuth propio (authorization code + PKCE + loopback)

**Fecha:** 2026-08-13
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Módulo Rust nuevo, autocontenido (sin bridge, sin Dart). Primera pieza de **SG-D** — ver `docs/superpowers/specs/2026-08-12-gcloud-removal-roadmap.md`.

## Objetivo

Implementar el flujo OAuth interactivo propio de LCC: abrir el navegador, recoger el `code` por redirección loopback y canjearlo por `access_token` + `refresh_token`, identificando la cuenta. Es la pieza que hace posible retirar `gcloud` de la autenticación, y la que resuelve el `invalid_rapt` de cuentas Workspace (la reauth se satisface relanzando el sign-in interactivo, como hace IAP Desktop).

D1 entrega **solo el núcleo**: módulo Rust con partes puras testeadas y un ejemplo ejecutable que valida el flujo real de punta a punta. Sin bridge (nada de regen) y sin tocar la app.

## Contexto

- **D0 hecho.** LCC tiene su propio client OAuth de tipo *Desktop app*:
  `743123147934-plp891qo2a44ie5jop1ud7n445gduk0h.apps.googleusercontent.com`
  Es un identificador **público por diseño** en clients instalados (el de IAP Desktop también lo es); PKCE es lo que protege el flujo, no un secreto. Se embebe en el código y puede vivir en el repo.
- **Categoría del scope confirmada en consola:** `cloud-platform` es **sensible** (no restringido) → la verificación de la app requiere política de privacidad, homepage y vídeo demo, pero **no** la auditoría CASA anual. La verificación es una vía paralela y **no bloquea** D1: en estado *Testing* con el propio usuario como test user, el flujo es plenamente funcional.
- **Piezas que ya existen en el repo:** `get_free_port()` (`tunnel.rs`, `pub(crate)`), `reqwest` con `json`, `rand`, `base64`, `tokio` con `net`/`time`/`macros`, `serde_json`, `redact_sensitive()` (`redact.rs`), el patrón `xdg-open` y `logging::block_on`. `crate-type = ["cdylib", "lib"]` y ya hay `native/examples/transfer_bench.rs` → los ejemplos compilan y hay precedente.
- **Solo falta la dependencia `sha2`** (para el `code_challenge` S256).
- `validate_gcp_url()` solo admite hosts `googleapis.com`. No estorba: a `accounts.google.com` **no se le hacen peticiones** (solo se abre el navegador ahí); el canje va contra `oauth2.googleapis.com`, que sí pasa la validación.

## Decisiones

| Decisión | Elección |
|---|---|
| Alcance de D1 | Módulo Rust autocontenido + ejemplo ejecutable. **Sin bridge, sin regen, sin Dart.** |
| Flujo | Authorization code + **PKCE S256** + redirección **loopback** (`http://127.0.0.1:<puerto efímero>`). OOB está deprecado por Google. |
| Puerto | Efímero vía `get_free_port()`; los clients Desktop **no** requieren pre-registrar el puerto. |
| Identificación de la cuenta | Email extraído del **payload del `id_token`**, sin verificar firma (llega directo del endpoint de token por TLS). Evita una llamada extra a `userinfo`. |
| Timeout | **5 minutos** esperando el redirect; al vencer, error claro y listener cerrado. |
| `client_secret` | **Condicional**: constante que puede estar vacía. Si la consola emitió secreto para este client, se embebe y se incluye en el canje; si está vacía, el canje va solo con PKCE. Se resuelve al implementar, mirando la consola. |
| Listener | `tokio::net::TcpListener` + parseo manual de la línea `GET`. **Sin** añadir servidor HTTP. |
| Dependencias nuevas | **Solo `sha2`.** |
| HTML de respuesta | Mínimo, en inglés — precedente del repo para cadenas producidas en Rust (no localizadas en esta fase). |

## Diseño

### 1. Módulo `native/src/oauth.rs` (declarado en `lib.rs` como `pub mod oauth;`)

Constantes:

```rust
const OAUTH_CLIENT_ID: &str = "743123147934-plp891qo2a44ie5jop1ud7n445gduk0h.apps.googleusercontent.com";
/// Desktop clients may be issued a non-confidential secret. Empty = PKCE only.
const OAUTH_CLIENT_SECRET: &str = "";
const AUTH_ENDPOINT: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";
const SCOPES: &str = "https://www.googleapis.com/auth/cloud-platform openid email";
const REDIRECT_TIMEOUT: Duration = Duration::from_secs(300);
```

Superficie pública (lo que consumirán D2/D3/D4):

```rust
pub struct OAuthTokens {
    pub email: String,
    pub refresh_token: String,
    pub access_token: String,
    pub expires_in_secs: u64,
}

/// Flujo interactivo completo: abre el navegador y devuelve los tokens.
pub async fn interactive_login() -> Result<OAuthTokens>;
```

### 2. El flujo (`interactive_login`)

1. Generar `code_verifier` aleatorio y `state` aleatorio; `code_challenge = base64url_nopad(SHA256(verifier))`.
2. `get_free_port()` → abrir `TcpListener` **solo en `127.0.0.1`**. `redirect_uri = http://127.0.0.1:<puerto>`.
3. Construir la URL de autorización y abrirla con `xdg-open`.
4. Aceptar **una** conexión con timeout de 5 min; leer la línea de petición; validar ruta y `state`; extraer `code` (o el `error=` que devuelva Google, p. ej. `access_denied`).
5. Responder al navegador con el HTML mínimo y **cerrar el listener** (pase lo que pase: éxito, error o timeout).
6. `POST` al endpoint de token con `code`, `code_verifier`, `client_id`, `redirect_uri`, `grant_type=authorization_code` (+ `client_secret` si la constante no está vacía) → `{access_token, refresh_token, id_token, expires_in}`.
7. Extraer el email del `id_token` y devolver `OAuthTokens`.

### 3. Seguridad

- **PKCE S256**: el `code` es inútil sin el `verifier`, aunque el `client_id` sea público.
- **`state`** comparado en **tiempo constante** → corta CSRF y redirects cruzados.
- Listener **loopback-only** (nunca `0.0.0.0`) y **de un solo uso**; cerrado siempre.
- **Secretos nunca en logs**: cualquier traza pasa por `redact_sensitive()`; el ejemplo imprime como mucho un prefijo del access token, nunca entero, y nunca el refresh token.
- Si falta el `refresh_token` en la respuesta, se devuelve error explícito (sin él la sesión no persiste).

### 4. Partes puras (tests unitarios reales, sin red)

- `generate_pkce() -> (verifier, challenge)` — verificar el `challenge` S256 contra el **vector conocido de la RFC 7636** (verifier `dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` → challenge `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`), y que dos llamadas dan verifiers distintos.
- `build_auth_url(...) -> String` — contiene client_id, redirect_uri, `code_challenge`, `code_challenge_method=S256`, `state`, scopes, `access_type=offline` y `prompt=consent`; todo correctamente url-encoded.

  **Por qué `prompt=consent`:** `access_type=offline` por sí solo hace que Google emita `refresh_token` en el **primer** consentimiento, pero en logins posteriores de la misma cuenta suele **omitirlo**, lo que rompería la persistencia de sesión (y el error "falta refresh_token" de §Errores saltaría en el segundo login). Forzar el consentimiento garantiza refresh token en cada login y encaja con el caso de reauth de Workspace, que precisamente quiere una autenticación fresca.
- `parse_redirect_request(request_line, expected_state) -> Result<String /*code*/>` — extrae `code`; detecta `error=access_denied`; rechaza ruta inesperada y `state` que no cuadra.
- `email_from_id_token(id_token) -> Result<String>` — decodifica el payload (segmento central, base64url) y saca `email`; error limpio si el JWT está malformado o no trae email.

### 5. Ejemplo ejecutable

`native/examples/oauth_login.rs`, siguiendo el patrón de `transfer_bench.rs` (doc-comment con propósito y uso). `cargo run --example oauth_login`: ejecuta el flujo real, imprime el email, si se obtuvo refresh token (sí/no, **nunca** el valor) y un prefijo corto del access token. Es el QA end-to-end de D1.

## Errores

Errores explícitos y accionables en cada punto de fallo: no hay `client_id` configurado, no se pudo abrir el navegador, timeout esperando el redirect, el usuario denegó el consentimiento (`access_denied`), `state` no coincide, el canje devolvió no-200, o la respuesta no trae `refresh_token`. Todos con `anyhow!` y texto en inglés (capa Rust); su localización llega cuando D4 los exponga por el bridge.

## Testing

- **`cargo test`**: los tests puros de §4 (PKCE contra vector RFC, URL de autorización, parseo del redirect incl. casos de error, extracción de email). Verdes sin red ni navegador.
- **`cargo build --release`** limpio y **`flutter test`** (suite) sin cambios — D1 no toca Dart.
- **QA manual end-to-end**: `cargo run --example oauth_login` completa el flujo con una cuenta real (en estado *Testing*, con el usuario como test user) y muestra el email correcto. Se documenta en un checklist.

## Alcance / fuera de alcance

- **Dentro:** `native/src/oauth.rs` (flujo + partes puras), `pub mod oauth;` en `lib.rs`, dependencia `sha2`, `native/examples/oauth_login.rs`, tests unitarios, checklist de QA manual.
- **Fuera:** almacén de tokens (**D2**), refresco y uso del token en el cliente REST (**D3**), gestión de cuentas + bridge + UI (**D4**), retirada de gcloud (**D5**); logout/revocación de tokens; localización de los mensajes de error; la verificación OAuth de la app ante Google (vía paralela, no bloquea).

## Verificación

- `cargo test` verde (incl. los tests puros nuevos), `cargo build --release` limpio, `flutter test` verde.
- `cargo run --example oauth_login` completa un login real y devuelve el email de la cuenta.
- Ni el refresh token ni el access token completo aparecen en logs ni en la salida del ejemplo.
