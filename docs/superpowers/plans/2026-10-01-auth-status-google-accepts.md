# auth_status comprueba que Google acepta la sesión — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Con el motor nativo, una credencial que el llavero entrega pero que Google ya no acepta deja
de contar como sesión: el panel pide iniciar sesión y dice por qué, en vez de mostrar un panel que
falla en todos los listados.

**Architecture:** En Rust, `gcp_rest_client` gana una comprobación tipada,
`check_native_session(plazo) -> SessionCheck { Accepted, Rejected, Unverified }`. Corre bajo el mismo
cerrojo de `TOKEN_CACHE` que los listados y deja en la caché el token que obtiene. `auth_status` la
llama solo cuando la credencial es `Readable`, y `AuthStatus` gana `session_rejected`. En Dart, el mapa
de estado lo lleva hasta la rama de iniciar sesión, que muestra una nota.

**Tech Stack:** Rust (tokio 1.48, reqwest), flutter_rust_bridge 2.11.1, Flutter + Riverpod 3.3.2,
flutter gen-l10n.

**Spec:** `docs/superpowers/specs/2026-10-01-auth-status-google-accepts-design.md` (commit 26c3732).

## Global Constraints

- Prohibido `#[allow(...)]` y silenciar lints; los avisos se arreglan en su causa.
- Secretos jamás en el log ni en la salida de un test: ni refresh tokens ni access tokens.
- No ejecutar `dart format`.
- Commits de código SIN trailer Co-Authored-By. Sin push. No se toca `lib/src/version.dart`.
- No commitear cambios ajenos: `analysis_options.yaml`, `native/Cargo.toml`,
  `.github/workflows/security.yml`, `native/deny.toml`, `lcc-crash.txt` y
  `docs/superpowers/plans/2026-09-30-qa-41-y-decision-main.md`.
- `git status` antes de cualquier suite completa.
- `SESSION_CHECK_TIMEOUT = 2 s`.
- A Google solo se le pregunta si la credencial es `Readable` y el motor es nativo.
- `Unverified` y `Unclear` conservan `authenticated` como hoy: sin respuesta de Google nunca se manda a
  iniciar sesión.
- Puente: `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart`.
  Hash actual: 1475522900. Añadir un campo NO lo cambia, así que se reconstruyen los dos lados juntos
  y se entregan los dos hashes.
- Línea base del analizador: 462 issues (árbol entero). Al terminar debe dar 462 o menos, sin avisos
  nuevos frente a HEAD.

## Review Focus

1. **Arranque sin red:** debe salir el panel, no la pantalla de iniciar sesión. Lo cubren
   `no_answer_from_google_is_unverified` (Tarea 1) y la fila `Unverified` de la tabla de
   `auth_status_for` (Tarea 1); en la app real, la QA (Tarea 4, paso 4).
2. **Red lenta o que pierde paquetes:** el panel no debe esperar más de 2 s. Lo cubre
   `a_slow_google_is_unverified_at_the_deadline` (Tarea 1).
3. **Motor gcloud:** nunca debe aparecer "sesión rechazada". Lo cubre
   `the_gcloud_route_never_reports_a_rejected_session` (Tarea 1).
4. **Doble intercambio:** la comprobación no debe hacer que los listados vuelvan a pedir token. Lo
   cubre `an_accepted_session_leaves_its_token_for_the_listings` (Tarea 1); en la app real, el conteo
   del paso 3 de la QA (Tarea 4).
5. **Sesión revocada con la app abierta:** el aviso de arriba debe salir al primer fallo. Es
   comportamiento existente (y 981761f); lo cubre la QA (Tarea 4, paso 5, caso 4b).

---

### Task 1: La comprobación tipada y `auth_status` (Rust + puente)

**Files:**
- Modify: `native/src/gcp_rest_client.rs`: `token_from_native_session` (~:240); añadir
  `SessionCheck`, `session_check_from`, `native_refresh_outcome`, `check_with`,
  `check_native_session` y `SESSION_CHECK_TIMEOUT`.
- Modify: `native/src/accounts.rs`: `AuthStatus` (~:87), `auth_status_for` (~:101-140) y
  `auth_status` (~:355-403).
- Regenerate: `lib/src/bridge/api.dart/**` y `native/src/frb_generated.rs`.
- Test: un módulo nuevo `session_check_tests` al final de `native/src/gcp_rest_client.rs`, y
  `mod tests` de `native/src/accounts.rs`.

**Interfaces:**
- Produces (Rust, `pub(crate)` en `gcp_rest_client`):
  - `enum SessionCheck { Accepted, Rejected, Unverified }` (`Debug, Clone, Copy, PartialEq, Eq`)
  - `const SESSION_CHECK_TIMEOUT: Duration` (2 s)
  - `async fn check_native_session(timeout: Duration) -> SessionCheck`
- Produces (puente): `AuthStatus.session_rejected: bool`. En Dart, tras regenerar,
  `final bool sessionRejected;` con `required this.sessionRejected` en el constructor.

- [ ] **Step 1: Tests de la comprobación (RED)**

Añadir al final de `native/src/gcp_rest_client.rs`:

```rust
#[cfg(test)]
mod session_check_tests {
    use super::*;
    use crate::oauth::{AuthEngine, RefreshOutcome, RefreshedToken};
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn token(t: &str) -> RefreshOutcome {
        RefreshOutcome::Token(RefreshedToken { access_token: t.to_string(), expires_in_secs: 3600 })
    }

    fn cache_with(engine: AuthEngine, age: Duration) -> tokio::sync::Mutex<Option<CachedToken>> {
        tokio::sync::Mutex::new(Some(CachedToken {
            token: "cached".to_string(),
            fetched_at: Instant::now() - age,
            engine,
        }))
    }

    const DEADLINE: Duration = Duration::from_secs(2);

    #[test]
    fn session_check_from_names_each_outcome() {
        assert_eq!(session_check_from(&Ok(token("t"))), SessionCheck::Accepted);
        assert_eq!(session_check_from(&Ok(RefreshOutcome::NeedsReauth)), SessionCheck::Rejected);
        assert_eq!(
            session_check_from(&Err(anyhow!("Token refresh request failed: dns"))),
            SessionCheck::Unverified
        );
    }

    /// Google minted this token less than TOKEN_CACHE_TTL ago, so it accepted
    /// the session then; asking again would cost a round trip for nothing.
    #[tokio::test]
    async fn a_fresh_native_token_in_the_cache_is_accepted_without_asking_google() {
        let calls = AtomicUsize::new(0);
        let cache = cache_with(AuthEngine::Native, Duration::from_secs(10));
        let check = check_with(&cache, DEADLINE, || {
            calls.fetch_add(1, Ordering::SeqCst);
            async { Ok(token("new")) }
        })
        .await;
        assert_eq!(check, SessionCheck::Accepted);
        assert_eq!(calls.load(Ordering::SeqCst), 0, "Google was asked anyway");
    }

    #[tokio::test]
    async fn a_token_from_the_other_engine_or_too_old_is_not_trusted() {
        for cache in [
            cache_with(AuthEngine::Gcloud, Duration::from_secs(10)),
            cache_with(AuthEngine::Native, TOKEN_CACHE_TTL + Duration::from_secs(1)),
        ] {
            let calls = AtomicUsize::new(0);
            check_with(&cache, DEADLINE, || {
                calls.fetch_add(1, Ordering::SeqCst);
                async { Ok(token("new")) }
            })
            .await;
            assert_eq!(calls.load(Ordering::SeqCst), 1, "a stale or foreign token was trusted");
        }
    }

    /// The listings that follow at startup reuse this token instead of
    /// exchanging the refresh token a second time.
    #[tokio::test]
    async fn an_accepted_session_leaves_its_token_for_the_listings() {
        let cache = tokio::sync::Mutex::new(None);
        let check = check_with(&cache, DEADLINE, || async { Ok(token("fresh")) }).await;
        assert_eq!(check, SessionCheck::Accepted);
        let cached = cache.lock().await;
        let cached = cached.as_ref().expect("the token was not cached");
        assert_eq!(cached.token, "fresh");
        assert!(cached.is_usable_for(AuthEngine::Native));
    }

    #[tokio::test]
    async fn a_rejected_session_is_rejected_and_caches_nothing() {
        let cache = tokio::sync::Mutex::new(None);
        let check = check_with(&cache, DEADLINE, || async { Ok(RefreshOutcome::NeedsReauth) }).await;
        assert_eq!(check, SessionCheck::Rejected);
        assert!(cache.lock().await.is_none());
    }

    /// Offline, a 5xx, a timeout of the HTTP client: no answer about the
    /// session. Sending the user to sign in would claim what nobody knows.
    #[tokio::test]
    async fn no_answer_from_google_is_unverified() {
        let cache = tokio::sync::Mutex::new(None);
        let check = check_with(&cache, DEADLINE, || async {
            Err(anyhow!("Token refresh request failed: error sending request"))
        })
        .await;
        assert_eq!(check, SessionCheck::Unverified);
    }

    /// The whole dashboard waits on auth_status: a network that drops packets
    /// must not hold it for the HTTP client's 30 s.
    #[tokio::test]
    async fn a_slow_google_is_unverified_at_the_deadline() {
        let cache = tokio::sync::Mutex::new(None);
        let t0 = Instant::now();
        let check = check_with(&cache, Duration::from_millis(50), || async {
            tokio::time::sleep(Duration::from_millis(500)).await;
            Ok(token("late"))
        })
        .await;
        assert_eq!(check, SessionCheck::Unverified);
        assert!(t0.elapsed() < Duration::from_millis(400), "waited {:?}", t0.elapsed());
    }
}
```

Run: `cd native && cargo test --lib gcp_rest_client::session_check_tests`
Expected: error de compilación, `SessionCheck` / `session_check_from` / `check_with` no existen.

- [ ] **Step 2: Implementar la comprobación**

En `native/src/gcp_rest_client.rs`, justo antes de `impl GcpAuthClient {`:

```rust
/// What Google said about the stored native session, as `auth_status` needs
/// it. Reading the credential from the keyring is not the same as Google
/// accepting it: on 2026-10-01 an `invalid_grant` session looked signed in and
/// every listing failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionCheck {
    /// Google exchanged the refresh token (now, or within `TOKEN_CACHE_TTL`).
    Accepted,
    /// Google refused it: `invalid_grant` / `rapt_required` / `invalid_rapt`.
    Rejected,
    /// No answer: offline, a 5xx, or the deadline. Treated as today's
    /// behaviour — never as a reason to send the user to sign in.
    Unverified,
}

/// How long `auth_status` waits for Google. The exchange takes 150–268 ms
/// (measured on 2026-10-01) and fails in about 20 ms with no network; 2 s is
/// eight times the healthy case. Past it the answer is `Unverified`, which
/// keeps the session as today, so a short deadline only costs missing a dead
/// session on a slow network — the session banner catches it on the first
/// listing — while a long one leaves the whole dashboard waiting.
pub(crate) const SESSION_CHECK_TIMEOUT: Duration = Duration::from_secs(2);

/// Pure, so each outcome is testable without Google.
fn session_check_from(outcome: &Result<crate::oauth::RefreshOutcome>) -> SessionCheck {
    match outcome {
        Ok(crate::oauth::RefreshOutcome::Token(_)) => SessionCheck::Accepted,
        Ok(crate::oauth::RefreshOutcome::NeedsReauth) => SessionCheck::Rejected,
        Err(_) => SessionCheck::Unverified,
    }
}

/// Load the active account's refresh token and exchange it. Shared by the
/// listings' token path and by the session check, so the two cannot disagree
/// about what Google said.
///
/// Every `token_store` call goes through `oauth::store_call`, which wraps it
/// in `spawn_blocking` — the store is synchronous and its keyring backend
/// drives its own runtime, which panics if entered from a tokio worker.
async fn native_refresh_outcome() -> Result<crate::oauth::RefreshOutcome> {
    let active = crate::oauth::store_call(crate::token_store::active_account).await?;
    let email = active.ok_or_else(|| {
        anyhow!("No signed-in Google Cloud account. Sign in to continue.")
    })?;
    debug!("Refreshing native access token for {}", email);
    let refresh_token =
        crate::oauth::store_call(move || crate::token_store::load_refresh_token(&email))
            .await??;
    crate::oauth::refresh_access_token(&refresh_token).await
}

/// The session check against `cache`, with the exchange passed in so tests
/// can stand in for Google. Holds the cache lock for the whole check, like
/// `get_access_token`, and leaves an accepted token in it for the listings.
async fn check_with<F, Fut>(
    cache: &tokio::sync::Mutex<Option<CachedToken>>,
    timeout: Duration,
    refresh: F,
) -> SessionCheck
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<crate::oauth::RefreshOutcome>>,
{
    let attempt = async {
        let mut cache = cache.lock().await;
        if let Some(cached) = cache.as_ref() {
            if cached.is_usable_for(crate::oauth::AuthEngine::Native) {
                return SessionCheck::Accepted;
            }
        }
        let outcome = refresh().await;
        if let Ok(crate::oauth::RefreshOutcome::Token(t)) = &outcome {
            *cache = Some(CachedToken {
                token: t.access_token.clone(),
                fetched_at: Instant::now(),
                engine: crate::oauth::AuthEngine::Native,
            });
        }
        session_check_from(&outcome)
    };
    tokio::time::timeout(timeout, attempt)
        .await
        .unwrap_or(SessionCheck::Unverified)
}

/// Does Google accept the stored native session? Called by `auth_status` only
/// when the keyring handed the credential over.
pub(crate) async fn check_native_session(timeout: Duration) -> SessionCheck {
    check_with(&*TOKEN_CACHE, timeout, native_refresh_outcome).await
}
```

Sustituir el cuerpo de `token_from_native_session` (conservando su comentario sobre `(invalid_grant)`)
por:

```rust
    async fn token_from_native_session(&self) -> Result<String> {
        match native_refresh_outcome().await? {
            crate::oauth::RefreshOutcome::Token(t) => Ok(t.access_token),
            // The trailing `(invalid_grant)` is the load-bearing part: it is
            // the token `classifyRustError` (lib/src/features/app_error.dart)
            // matches to raise the reauth banner. The prose around it is what
            // the user reads; without the marker the error classifies as
            // `unknown` and no banner appears. The browser is NOT opened here
            // — see oauth::ensure_signed_in.
            crate::oauth::RefreshOutcome::NeedsReauth => {
                debug!("Refresh token rejected; needs reauth");
                Err(anyhow!(
                    "Your Google Cloud session needs to be renewed: sign in again. (invalid_grant)"
                ))
            }
        }
    }
```

y su doc comment: "Access token from LCC's own stored session (SG-D). No gcloud and no fallback:
a failure here is reported, never masked. The exchange itself is `native_refresh_outcome`, shared
with the session check."

Run: `cd native && cargo test --lib gcp_rest_client`
Expected: PASS, `session_check_tests` incluido. Habrá un `dead_code` sobre `check_native_session` /
`SESSION_CHECK_TIMEOUT` hasta el Step 4; se resuelve dentro de esta tarea.

- [ ] **Step 3: Tabla de `auth_status_for` (RED)**

En `native/src/accounts.rs`, `mod tests`: añadir `use crate::gcp_rest_client::SessionCheck;` y añadir
el quinto argumento `None` a todas las llamadas de una línea que ya existen:

```bash
cd /home/jlopezre/GitHub/LCC/native && python3 - <<'PY'
import re
p='src/accounts.rs'; s=open(p).read()
# Only the existing one-line calls inside the tests: four arguments, the last
# being None or Some(CredentialState::…).
s=re.sub(r"(auth_status_for\(AuthEngine::\w+, (?:true|false), (?:true|false), (?:None|Some\(CredentialState::\w+\)|credential))\)",
         r"\1, None)", s)
open(p,'w').write(s)
PY
grep -n "auth_status_for(AuthEngine" src/accounts.rs
```

Comprobar con el `grep` que cada llamada tiene cinco argumentos. Después añadir:

```rust
    /// Google tiene la última palabra sobre una credencial que el llavero
    /// entregó. Sin respuesta (Unverified) o sin preguntar (None), la sesión
    /// se queda como hoy: nunca se manda a iniciar sesión por no saber.
    #[test]
    fn google_has_the_last_word_on_a_readable_credential() {
        use SessionCheck::*;
        for (google, authenticated, rejected) in [
            (Some(Accepted), true, false),
            (Some(Rejected), false, true),
            (Some(Unverified), true, false),
            (None, true, false),
        ] {
            let s = auth_status_for(
                AuthEngine::Native,
                true,
                true,
                Some(CredentialState::Readable),
                google,
            );
            assert_eq!(s.authenticated, authenticated, "{google:?}");
            assert_eq!(s.session_rejected, rejected, "{google:?}");
            assert_eq!(s.keyring_problem, None, "{google:?}");
        }
    }

    /// A Google verdict cannot override what the keyring said: a refused
    /// credential stays a keyring problem, not a rejected session.
    #[test]
    fn google_is_not_consulted_for_an_unreadable_credential() {
        let s = auth_status_for(
            AuthEngine::Native,
            true,
            true,
            Some(CredentialState::Refused),
            Some(SessionCheck::Rejected),
        );
        assert!(!s.session_rejected);
        assert_eq!(s.keyring_problem, Some(KeyringProblem::Refused));
    }

    #[test]
    fn the_gcloud_route_never_reports_a_rejected_session() {
        let s = auth_status_for(
            AuthEngine::Gcloud,
            true,
            true,
            Some(CredentialState::Readable),
            Some(SessionCheck::Rejected),
        );
        assert!(s.authenticated);
        assert!(!s.session_rejected);
    }
```

Run: `cd native && cargo test --lib accounts`
Expected: error de compilación: `auth_status_for` recibe 4 argumentos y no existe `session_rejected`.

- [ ] **Step 4: `session_rejected`, `auth_status_for` y el cableado**

En `native/src/accounts.rs`:
- añadir `use crate::gcp_rest_client::SessionCheck;` a los `use`;
- añadir a `AuthStatus`:

```rust
    /// Under the native engine, the keyring handed the credential over but
    /// Google refused it (`invalid_grant`): there is no session, and the
    /// sign-in screen says why. Always `false` under the gcloud engine.
    pub session_rejected: bool,
```

- cambiar la firma de `auth_status_for` añadiendo `google: Option<SessionCheck>` como último
  parámetro, y su final por:

```rust
    // Google has the last word, but only on a credential the keyring handed
    // over: a keyring problem is not a rejected session.
    let session_rejected = matches!(route(engine), Route::Native)
        && native_credential == Some(CredentialState::Readable)
        && google == Some(SessionCheck::Rejected);
    // Pure, so the flag the dashboard gate reads is unit-testable without a
    // machine that lacks gcloud.
    let gcloud_required = matches!(route(engine), Route::Gcloud);
    AuthStatus {
        gcloud_installed,
        authenticated: authenticated && !session_rejected,
        gcloud_required,
        keyring_problem,
        session_rejected,
    }
```

  y añadir a su doc comment: "`google` is what Google said about a `Readable` credential (`None`
  when it was not asked); only `Rejected` changes the answer."
- en `auth_status`, sustituir `auth_status_for(engine, gcloud_installed, gcloud_authenticated, native_credential)` por:

```rust
    // Ask Google only about a credential the keyring handed over, and only on
    // the native route: anything else has no stored session to check.
    let google = if matches!(route(engine), Route::Native)
        && native_credential == Some(CredentialState::Readable)
    {
        Some(
            crate::gcp_rest_client::check_native_session(
                crate::gcp_rest_client::SESSION_CHECK_TIMEOUT,
            )
            .await,
        )
    } else {
        None
    };
    auth_status_for(engine, gcloud_installed, gcloud_authenticated, native_credential, google)
```

Run: `cd native && cargo test --lib accounts && cargo test --lib gcp_rest_client`
Expected: PASS. Fallará la compilación de `frb_generated.rs` (construye `AuthStatus`): es lo
esperado y se arregla en el Step 5. Si es así, pasar al Step 5 y repetir este Run después.

- [ ] **Step 5: Regenerar el puente y reconstruir los dos lados**

```bash
cd /home/jlopezre/GitHub/LCC
/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
grep -n "rustContentHash" lib/src/bridge/api.dart/frb_generated.dart
grep -n "FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH: i32" native/src/frb_generated.rs
grep -n "sessionRejected" lib/src/bridge/api.dart/accounts.dart
git status --short lib/src/bridge native/src
cd native && cargo test --lib accounts && cargo test --lib gcp_rest_client && cargo build --lib && cargo build --release --lib
```

Expected: los dos hashes iguales (anotar el valor); `accounts.dart` con `final bool sessionRejected;`;
solo cambian los ficheros del puente; tests en verde; builds sin errores.

El campo es `required` en el constructor Dart, así que `test/dashboard_gate_test.dart` deja de
compilar. En su helper `_native`, añadir `sessionRejected: false,` a la llamada a `AuthStatus(...)`
(la Tarea 2 lo convierte en parámetro), y comprobar:
`flutter test test/dashboard_gate_test.dart` → PASS.

- [ ] **Step 6: Suite nativa, clippy, commit**

```bash
cd /home/jlopezre/GitHub/LCC && git status --short
cd native && cargo test 2>&1 | grep -E "test result|FAILED"
cargo clippy --lib --tests 2>&1 | grep -E -A6 "src/(gcp_rest_client|accounts)\.rs" | head -40
```

Expected: la suite entera en verde. En clippy, ningún aviso en líneas tocadas; los que salgan en
`gcp_rest_client.rs` hay que compararlos con HEAD (`git stash` no vale en el árbol compartido: copiar
el fichero aparte, restaurar HEAD, medir y volver a copiarlo).

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/gcp_rest_client.rs native/src/accounts.rs native/src/frb_generated.rs lib/src/bridge/api.dart test/dashboard_gate_test.dart
git commit -m "feat(auth): auth_status pregunta a Google por una credencial que el llavero entrega"
```

---

### Task 2: El mapa de estado lleva `sessionRejected` (Dart)

**Files:**
- Modify: `lib/src/features/dashboard_gate.dart` (`statusMapFor`)
- Modify: `test/dashboard_gate_test.dart` (helper `_native` y tests nuevos)

**Interfaces:**
- Consumes: `AuthStatus.sessionRejected` (Tarea 1).
- Produces: la clave `'sessionRejected'` en el mapa de `gcloudStatusProvider`.

- [ ] **Step 1: Tests (RED)**

En `test/dashboard_gate_test.dart`, el helper `_native` pasa a aceptar `bool sessionRejected = false`
y a pasarlo al constructor (`sessionRejected: sessionRejected`). Añadir en el grupo `statusMapFor`:

```dart
    test('a session Google rejected travels in the map', () {
      final map = statusMapFor(
          _native(authenticated: false, sessionRejected: true));
      expect(map['sessionRejected'], isTrue);
      expect(statusMapFor(_native(authenticated: true))['sessionRejected'],
          isFalse);
    });
```

y en el grupo `dashboardGateFor`:

```dart
    // A rejected session is not a keyring problem: the credential was read
    // fine, Google refused it. The way out is signing in again.
    test('a session Google rejected asks to sign in', () {
      expect(dashboardGateFor({'authenticated': false, 'sessionRejected': true}),
          DashboardGate.signIn);
    });
```

Run: `flutter test test/dashboard_gate_test.dart`
Expected: FAIL: `map['sessionRejected']` es null, no `true`. El test del gate ya pasa, porque la
regla existente lo cubre; queda como guarda del orden.

- [ ] **Step 2: Implementar**

En `statusMapFor` (`lib/src/features/dashboard_gate.dart`) añadir al mapa:

```dart
    // Google refused a credential the keyring handed over; the sign-in screen
    // says so (see SessionRejectedNote).
    'sessionRejected': status.sessionRejected,
```

Run: `flutter test test/dashboard_gate_test.dart test/projects_provider_test.dart`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/src/features/dashboard_gate.dart test/dashboard_gate_test.dart
git commit -m "feat(dashboard): el estado de sesión dice si Google rechazó la credencial"
```

---

### Task 3: La nota en la pantalla de iniciar sesión (Dart + l10n)

**Files:**
- Create: `lib/src/features/session_rejected_note.dart`
- Modify: `lib/l10n/app_en.arb` y `lib/l10n/app_es.arb` (después de `dashboardLoginButton`)
- Regenerate: `lib/l10n/gen/*` (`flutter gen-l10n`)
- Modify: `lib/main.dart`, rama `if (gate == DashboardGate.signIn)`
- Test: `test/session_rejected_note_test.dart`; `test/es_overflow_test.dart` (una entrada)

**Interfaces:**
- Consumes: `'sessionRejected'` del mapa (Tarea 2).
- Produces: `const SessionRejectedNote()`.

- [ ] **Step 1: Textos**

`lib/l10n/app_en.arb`, después de `"dashboardLoginButton"`:

```json
  "dashboardSessionRejectedNote": "Your Google session has expired or been revoked; sign in again.",
```

`lib/l10n/app_es.arb`, después de `"dashboardLoginButton"`:

```json
  "dashboardSessionRejectedNote": "Tu sesión de Google ha caducado o se ha revocado; inicia sesión otra vez.",
```

Run: `flutter gen-l10n` y comprobar que `git diff --stat lib/l10n` solo añade líneas.

- [ ] **Step 2: Test del widget (RED)**

`test/session_rejected_note_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/session_rejected_note.dart';

void main() {
  // Without it the sign-in screen looked like a fresh install: a button and no
  // reason, for a user whose session had worked until that morning.
  testWidgets('the sign-in screen says the session expired or was revoked',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SessionRejectedNote()),
    ));
    expect(find.textContaining('expired or been revoked'), findsOneWidget);
  });
}
```

Run: `flutter test test/session_rejected_note_test.dart`
Expected: FAIL, `session_rejected_note.dart` no existe.

- [ ] **Step 3: El widget**

`lib/src/features/session_rejected_note.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

/// Shown above the sign-in button when the keyring handed the credential over
/// but Google refused it. The button alone reads like a fresh install; this
/// line says the session existed and is what has to be renewed.
class SessionRejectedNote extends StatelessWidget {
  const SessionRejectedNote({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Text(
          l10n.dashboardSessionRejectedNote,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.orange.shade900),
        ),
      ),
    );
  }
}
```

Run: `flutter test test/session_rejected_note_test.dart`
Expected: PASS.

- [ ] **Step 4: El desbordamiento en español**

En `test/es_overflow_test.dart`, importar
`package:linux_cloud_connector/src/features/session_rejected_note.dart` y añadir a `_dialogs`:

```dart
  'SessionRejectedNote': () => const SessionRejectedNote(),
```

Run: `flutter test test/es_overflow_test.dart`
Expected: PASS en los 3 tamaños.

- [ ] **Step 5: Conectarlo en `main.dart`**

Importar `src/features/session_rejected_note.dart` (en formato package:, como los otros imports
nuevos). En la rama `if (gate == DashboardGate.signIn) {`, sustituir:

```dart
            return Center(
              child: ElevatedButton.icon(
```

por:

```dart
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (status['sessionRejected'] == true)
                    const SessionRejectedNote(),
                  ElevatedButton.icon(
```

y el cierre de esa rama:

```dart
                label: Text(l10n.dashboardLoginButton),
              ),
            );
          }
```

por:

```dart
                label: Text(l10n.dashboardLoginButton),
              ),
                ],
              ),
            );
          }
```

(El cuerpo del botón no cambia. No ejecutar `dart format`.)

Run:

```bash
cd /home/jlopezre/GitHub/LCC && git status --short
flutter test 2>&1 | tail -1
flutter analyze 2>&1 | tail -1
```

Expected: la suite entera en verde y el analizador en 462 o menos. Si sube, comparar la lista de
avisos con la de HEAD (sin números de línea) y arreglar el aviso nuevo antes de seguir.

- [ ] **Step 6: Commit**

```bash
git add lib/src/features/session_rejected_note.dart lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen lib/main.dart test/session_rejected_note_test.dart test/es_overflow_test.dart
git commit -m "feat(dashboard): la pantalla de iniciar sesión dice que Google rechazó la sesión"
```

---

### Task 4: Mutaciones, entrega del puente y QA real

- [ ] **Step 1: Mutaciones (cada una debe poner en rojo el test indicado)**

| # | Mutación | Test que debe caer |
|---|---|---|
| G1 | `session_check_from`: `NeedsReauth` → `Unverified` | `session_check_from_names_each_outcome`, `a_rejected_session_is_rejected_and_caches_nothing` |
| G2 | `session_check_from`: `Err` → `Rejected` | `no_answer_from_google_is_unverified` |
| G3 | `check_with` no mira la caché | `a_fresh_native_token_in_the_cache_is_accepted_without_asking_google` |
| G4 | `check_with` acepta la caché de cualquier motor o edad (sin `is_usable_for`) | `a_token_from_the_other_engine_or_too_old_is_not_trusted` |
| G5 | `check_with` no guarda el token | `an_accepted_session_leaves_its_token_for_the_listings` |
| G6 | sin `tokio::time::timeout` | `a_slow_google_is_unverified_at_the_deadline` |
| G7 | `auth_status_for`: `Unverified` cuenta como rechazo | `google_has_the_last_word_on_a_readable_credential` |
| G8 | `auth_status_for`: sin la condición `Readable` | `google_is_not_consulted_for_an_unreadable_credential` |
| G9 | `auth_status_for`: sin la condición `Route::Native` | `the_gcloud_route_never_reports_a_rejected_session` |
| G10 | `statusMapFor`: `'sessionRejected': false` | `a session Google rejected travels in the map` |
| W1 | cableado: `auth_status` con `google = None` siempre | ninguno, previsto. Lo cubre la QA (paso 5): anotar NOT COVERED en `accounts.rs` |
| W2 | `main.dart`: sin la nota | ninguno, previsto. Lo cubre la QA (paso 5): anotar NOT COVERED en `main.dart` |

- [ ] **Step 2: Entregar los hashes del puente** a la otra sesión (Dart y Rust), con los commits y
  las mutaciones. La build la monta esa sesión.

- [ ] **Step 3: QA, arranque sano.** Con la build nueva, arrancar con
  `RUST_LOG=info,native::gcp_rest_client=debug`. Expected: el panel sin espera visible. En el log,
  UNA línea "Refreshing native access token" antes del primer "Listing GCP projects", no dos.

- [ ] **Step 4: QA, sin red.** `bwrap --dev-bind / / --unshare-net <binario>`. Expected: el panel
  (`Unverified`), no la pantalla de iniciar sesión. Los listados fallan por red y NO sale el aviso de
  sesión caducada.

- [ ] **Step 5: QA, sesión rechazada** (SOLO con el consentimiento explícito del usuario; luego
  tendrá que volver a iniciar sesión). Revocar el refresh token de LCC con un test temporal que lo
  lea del llavero y haga POST a `https://oauth2.googleapis.com/revoke`, sin imprimirlo.
  - 4a: al arrancar sale la pantalla de iniciar sesión con la nota.
  - 4b: si se revoca con la app ya abierta y se refresca la lista, el aviso de arriba sale al primer
    fallo, sin reintentos (981761f).
  - Al terminar, el usuario vuelve a iniciar sesión y se comprueba que el panel carga.
