# auth_status sabe si la credencial se puede leer — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Con el motor nativo, `auth_status` deja de decir "autenticado" cuando la credencial de la
cuenta activa no se puede leer del llavero. El panel muestra una pantalla que dice la verdad, sin
reintentos inútiles y con un botón para volver a comprobar sin reiniciar la app.

**Architecture:** En Rust, `token_store` clasifica la lectura real de la entrada de la cuenta activa.
La lectura tiene un plazo de 3 s y hay una sola en curso por cuenta. `accounts::auth_status` traduce
el resultado a `authenticated` y a `keyring_problem`, un campo nuevo que cruza el puente. En Dart,
una función pura decide qué pantalla mostrar, y un widget nuevo muestra el problema del llavero con
el botón Comprobar de nuevo.

**Tech Stack:** Rust (keyring 3.6.3, tokio 1.48 `watch`), flutter_rust_bridge 2.11.1, Flutter +
Riverpod 3.3.2, flutter gen-l10n.

**Spec:** `docs/superpowers/specs/2026-09-30-auth-status-keyring-design.md` (commits 2fd255f y ebc639e).

## Global Constraints

- Prohibido `#[allow(...)]` y silenciar lints. Si clippy protesta, se arregla la causa.
- Los secretos jamás van al log. En `Readable` el valor leído se descarta en el acto.
- No ejecutar `dart format`.
- Los commits de código van SIN trailer Co-Authored-By. No hay push. No se toca `lib/src/version.dart`.
- No commitear cambios ajenos: `analysis_options.yaml`, `native/Cargo.toml`,
  `.github/workflows/security.yml`, `native/deny.toml`, `lcc-crash.txt` y
  `docs/superpowers/plans/2026-09-30-qa-41-y-decision-main.md`.
- Hacer `git status` antes de pasar cualquier suite completa.
- `CREDENTIAL_READ_TIMEOUT = 3 s`.
- El puente lo regenera esta sesión con
  `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart`.
  Hash antes del cambio: 1475522900 en los dos lados. Añadir un campo NO cambia el hash, así que se
  reconstruyen los dos lados juntos y se entregan los dos hashes.
- Textos EN y ES para todo texto nuevo. Ningún texto afirma una causa que el código no puede
  distinguir ("bloqueado o se canceló", no "está bloqueado").

## Review Focus

1. **Arranque en frío con el llavero sano:** no debe aparecer *Pending*. Si arrancar gnome-keyring
   por activación D-Bus supera los 3 s, el plazo se queda corto. Lo cubre la QA (Tarea 6, paso 5),
   porque solo se ve en un arranque real.
2. **El usuario pulsa Comprobar de nuevo varias veces con el diálogo detrás de la ventana:** no se
   deben apilar diálogos. Lo cubre `a_second_check_while_waiting_joins_the_same_read` (Tarea 2).
3. **Se cambia de cuenta mientras hay una lectura en curso de la cuenta anterior:** la cuenta nueva
   no debe esperar a la vieja. Lo cubre `different_accounts_do_not_share_a_read` (Tarea 2).
4. **El hilo lector muere sin contestar:** ninguna comprobación posterior debe quedarse enganchada a
   una ranura muerta. Lo cubre `a_reader_that_dies_leaves_no_stale_slot` (Tarea 2).
5. **El índice dice que hay cuenta activa pero su entrada ha desaparecido del llavero:** debe salir
   la pantalla de iniciar sesión, no la del llavero. Lo cubre la tabla de `auth_status_for` (fila
   `Missing`, Tarea 2) y `dashboardGateFor` (Tarea 3).

---

### Task 1: El error del llavero deja de decir "no hay Secret Service" cuando está bloqueado

Hoy `keyring_backend_error` pone `NoStorageAccess` (bloqueado o diálogo cancelado) y
`PlatformFailure` (servicio inalcanzable) bajo el mismo texto, "no Secret Service … is running". Es
falso con el llavero bloqueado (medido: cancelar el diálogo da `NoStorageAccess`, "SS error: prompt
dismissed").

**Files:**
- Modify: `native/src/token_store.rs:159-180` (`keyring_backend_error`)
- Test: `native/src/token_store.rs`, módulo `tests` (reescribir `a_down_backend_is_not_health` y
  `classify_probe_treats_a_down_backend_as_failure_not_entry_as_health`, añadir uno)

**Interfaces:**
- Consumes: nada nuevo.
- Produces: los textos nuevos. `PlatformFailure` → contiene "could not be reached" y "Secret
  Service". `NoStorageAccess` → contiene "refused access" y "locked", y NO contiene "Secret Service".

- [ ] **Step 1: Reescribir y añadir los tests (RED)**

En `mod tests` de `native/src/token_store.rs`, sustituir `a_down_backend_is_not_health` y
`classify_probe_treats_a_down_backend_as_failure_not_entry_as_health` por:

```rust
    /// La sonda tiene que distinguir "el servicio respondió y no hay registro"
    /// de "el servicio no está". Si tratara ambos como salud, Doctor daría
    /// verde con el llavero caído, que es exactamente lo que pasó en D2.
    #[test]
    fn a_down_backend_is_not_health() {
        let down = keyring_backend_error(
            keyring::Error::PlatformFailure(Box::new(std::io::Error::other("no service"))),
            "read",
        );
        assert!(down.to_string().contains("could not be reached"), "{down}");
    }

    /// Medido el 2026-09-30: con el llavero bloqueado y el diálogo cancelado,
    /// keyring devuelve NoStorageAccess ("SS error: prompt dismissed"). Hay un
    /// Secret Service en marcha; decirle al usuario que arranque uno es mandarle
    /// a arreglar algo que no está roto.
    #[test]
    fn a_locked_keyring_is_not_reported_as_a_missing_service() {
        let refused = keyring_backend_error(
            keyring::Error::NoStorageAccess(Box::new(std::io::Error::other(
                "SS error: prompt dismissed",
            ))),
            "read",
        )
        .to_string();
        assert!(refused.contains("refused access"), "{refused}");
        assert!(refused.contains("locked"), "{refused}");
        assert!(!refused.contains("Secret Service"), "{refused}");
    }

    /// El guardián real de la sonda: ejercita `classify_probe`, que es lo que
    /// `probe_keyring` llama de verdad. Un guardián sobre `keyring_backend_error`
    /// a solas no dice nada de si la sonda pasa por él o lo esquiva.
    #[test]
    fn classify_probe_treats_a_down_backend_as_failure_not_entry_as_health() {
        let down = classify_probe(Err(keyring::Error::PlatformFailure(Box::new(
            std::io::Error::other("no service"),
        ))));
        let down_err = down.expect_err("a down backend must not classify as Ok");
        assert!(down_err.to_string().contains("could not be reached"));

        let refused = classify_probe(Err(keyring::Error::NoStorageAccess(Box::new(
            std::io::Error::other("locked"),
        ))));
        assert!(refused.is_err(), "a refused backend is not health either");

        assert!(classify_probe(Err(keyring::Error::NoEntry)).is_ok());
        assert!(classify_probe(Ok("irrelevant".to_string())).is_ok());
    }
```

- [ ] **Step 2: Comprobar que fallan por la razón esperada**

Run: `cd native && cargo test --lib token_store`
Expected: FAIL en los tres. `could not be reached` y `refused access` todavía no existen.

- [ ] **Step 3: Separar el texto por variante**

Sustituir el cuerpo de `keyring_backend_error` en `native/src/token_store.rs` por:

```rust
fn keyring_backend_error(e: keyring::Error, verb: &str) -> anyhow::Error {
    match &e {
        keyring::Error::PlatformFailure(_) => anyhow!(
            "The system keyring could not be reached, so the sign-in cannot be {}. \
             On Linux this usually means no Secret Service (GNOME Keyring or \
             KWallet) is running: {}",
            verb,
            e
        ),
        // Measured: a locked collection, or an unlock prompt the user
        // dismissed, lands here. A Secret Service IS running, so this message
        // must not send the user off to start one.
        keyring::Error::NoStorageAccess(_) => anyhow!(
            "The system keyring refused access, so the sign-in cannot be {}: it is \
             locked, or the unlock was cancelled: {}",
            verb,
            e
        ),
        _ => anyhow!(
            "Failed to {} the sign-in in the system keyring: {}",
            verb,
            e
        ),
    }
}
```

Actualizar también su comentario de documentación: separa "down backend" (`PlatformFailure`) de
"refused" (`NoStorageAccess`).

- [ ] **Step 4: Comprobar que pasan**

Run: `cd native && cargo test --lib token_store`
Expected: PASS.

- [ ] **Step 5: Buscar a quien dependa del texto viejo**

Run: `grep -rn "keyring is unavailable" native/src lib test`
Expected: sin resultados. Si sale alguno, adaptarlo a la variante que corresponda.

- [ ] **Step 6: Commit**

```bash
git add native/src/token_store.rs
git commit -m "fix(token-store): un llavero bloqueado deja de reportarse como Secret Service ausente"
```

---

### Task 2: auth_status lee la credencial real, con plazo y una sola lectura en curso (Rust + puente)

**Files:**
- Modify: `native/src/token_store.rs` (añadir `CredentialState`, `classify_credential`,
  `read_credential`, `InFlightReads`, `CREDENTIAL_READ_TIMEOUT` y `credential_state_within`, junto
  a `probe_keyring`)
- Modify: `native/src/accounts.rs:79-115` (`AuthStatus`, `KeyringProblem` y `auth_status_for`) y
  `:331-357` (`auth_status`)
- Regenerate: `lib/src/bridge/api.dart/**` y `native/src/frb_generated.rs`
- Test: `native/src/token_store.rs` (`mod tests` y un módulo nuevo `credential_read_tests`) y
  `native/src/accounts.rs` (`mod tests`)

**Interfaces:**
- Produces (Rust, `pub(crate)` en `token_store`):
  - `enum CredentialState { Readable, Missing, Unreachable, Refused, Pending, Unclear }` (con
    `Debug, Clone, Copy, PartialEq, Eq`)
  - `const CREDENTIAL_READ_TIMEOUT: std::time::Duration` (3 s)
  - `async fn credential_state_within(email: &str, timeout: std::time::Duration) -> CredentialState`
- Produces (puente, `accounts`):
  - `pub enum KeyringProblem { Unreachable, Refused, Pending }`
  - `AuthStatus.keyring_problem: Option<KeyringProblem>`
- En Dart, tras regenerar: `KeyringProblem { unreachable, refused, pending }` y
  `AuthStatus.keyringProblem: KeyringProblem?`, en `lib/src/bridge/api.dart/accounts.dart`.

- [ ] **Step 1: Tests de `classify_credential` (RED)**

Añadir a `mod tests` de `native/src/token_store.rs`:

```rust
    fn io(msg: &str) -> Box<dyn std::error::Error + Send + Sync> {
        Box::new(std::io::Error::other(msg.to_string()))
    }

    /// Las cinco salidas, cada una con el error que la produce. Las de
    /// PlatformFailure y NoStorageAccess reproducen lo medido el 2026-09-30.
    #[test]
    fn classify_credential_names_each_outcome() {
        assert_eq!(classify_credential(Ok("secret".into())), CredentialState::Readable);
        assert_eq!(classify_credential(Err(keyring::Error::NoEntry)), CredentialState::Missing);
        assert_eq!(
            classify_credential(Err(keyring::Error::PlatformFailure(io(
                "no secret service provider or dbus session found"
            )))),
            CredentialState::Unreachable
        );
        assert_eq!(
            classify_credential(Err(keyring::Error::NoStorageAccess(io("SS error: prompt dismissed")))),
            CredentialState::Refused
        );
        assert_eq!(
            classify_credential(Err(keyring::Error::BadEncoding(vec![0xff]))),
            CredentialState::Unclear
        );
    }
```

Run: `cd native && cargo test --lib token_store::tests::classify_credential`
Expected: error de compilación, `classify_credential` / `CredentialState` no existen.

- [ ] **Step 2: Implementar `CredentialState`, `classify_credential` y `read_credential`**

Añadir en `native/src/token_store.rs`, después de `probe_keyring`:

```rust
/// What reading the account's own keyring entry says about using it now.
///
/// `auth_status` used to answer "is there an active account?" from the index
/// alone, and the whole app read that as "can I use its credential?". With the
/// keyring down or locked the app believed itself signed in and retried
/// listings that could not succeed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CredentialState {
    /// The entry was read. Its value is dropped on the spot, never logged.
    Readable,
    /// The backend answered and holds no entry for this account.
    Missing,
    /// No Secret Service answered (`PlatformFailure`), e.g. no D-Bus session.
    Unreachable,
    /// A Secret Service answered and refused (`NoStorageAccess`): the
    /// collection is locked, or the unlock prompt was dismissed.
    Refused,
    /// No answer within the deadline: most likely an unlock prompt is waiting
    /// for the user.
    Pending,
    /// Any other error. Treated as usable, today's behaviour: nothing we cannot
    /// classify may put up a keyring screen that could be false.
    Unclear,
}

/// Pure, so each outcome is testable with a fabricated `keyring::Error`.
fn classify_credential(result: std::result::Result<String, keyring::Error>) -> CredentialState {
    match result {
        Ok(_) => CredentialState::Readable,
        Err(keyring::Error::NoEntry) => CredentialState::Missing,
        Err(keyring::Error::PlatformFailure(_)) => CredentialState::Unreachable,
        Err(keyring::Error::NoStorageAccess(_)) => CredentialState::Refused,
        Err(_) => CredentialState::Unclear,
    }
}

/// Read `email`'s real entry — not the probe key. "Backend up but this
/// account's entry is gone" is also permanent, and the probe would call it
/// healthy.
fn read_credential(email: &str) -> CredentialState {
    match Entry::new(SERVICE_NAME, &keyring_key(email)) {
        Ok(entry) => classify_credential(entry.get_password()),
        Err(_) => CredentialState::Unclear,
    }
}
```

Run: `cd native && cargo test --lib token_store::tests::classify_credential`
Expected: PASS. Hay avisos de `dead_code` hasta el Step 6; se resuelven en esta misma tarea, antes
del commit.

- [ ] **Step 3: Tests de plazo y lectura única (RED)**

Añadir al final de `native/src/token_store.rs`:

```rust
#[cfg(test)]
mod credential_read_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{mpsc, Arc};
    use std::time::Duration;

    const SHORT: Duration = Duration::from_millis(50);
    const LONG: Duration = Duration::from_secs(5);

    /// A reader that blocks until the test sends it the answer, and counts how
    /// many reads were started.
    fn gated(
        count: &Arc<AtomicUsize>,
    ) -> (mpsc::Sender<CredentialState>, impl FnOnce() -> CredentialState + Send + 'static) {
        let (tx, rx) = mpsc::channel();
        let count = count.clone();
        let reader = move || {
            count.fetch_add(1, Ordering::SeqCst);
            rx.recv().unwrap_or(CredentialState::Unclear)
        };
        (tx, reader)
    }

    #[tokio::test]
    async fn a_quick_answer_is_returned_not_pending() {
        let reads = InFlightReads::default();
        let state = reads.state("a@x", LONG, || CredentialState::Readable).await;
        assert_eq!(state, CredentialState::Readable);
    }

    /// The defect this deadline exists for: the whole dashboard body hangs on
    /// gcloudStatusProvider (main.dart:625), and an unanswered unlock prompt
    /// kept the read waiting for more than 180 s.
    #[tokio::test]
    async fn a_read_that_outlasts_the_deadline_is_pending() {
        let count = Arc::new(AtomicUsize::new(0));
        let (answer, reader) = gated(&count);
        let reads = InFlightReads::default();

        assert_eq!(reads.state("a@x", SHORT, reader).await, CredentialState::Pending);
        let _ = answer.send(CredentialState::Readable);
    }

    /// Pressing "Check again" with the prompt still open, maybe behind the
    /// window, must not start a second read: we do not know how the keyring
    /// handles two unlock prompts, and this way it does not matter.
    #[tokio::test]
    async fn a_second_check_while_waiting_joins_the_same_read() {
        let count = Arc::new(AtomicUsize::new(0));
        let (answer, first) = gated(&count);
        let (_unused, second) = gated(&count);
        let reads = InFlightReads::default();

        assert_eq!(reads.state("a@x", SHORT, first).await, CredentialState::Pending);
        assert_eq!(reads.state("a@x", SHORT, second).await, CredentialState::Pending);
        assert_eq!(count.load(Ordering::SeqCst), 1, "a second read was started");
        let _ = answer.send(CredentialState::Readable);
    }

    /// The read is not cancelled at the deadline: when the user finally
    /// unlocks, a waiter still inside its own deadline gets the real answer.
    #[tokio::test]
    async fn a_waiter_gets_the_answer_when_it_arrives() {
        let count = Arc::new(AtomicUsize::new(0));
        let (answer, reader) = gated(&count);
        let reads = Arc::new(InFlightReads::default());

        assert_eq!(reads.state("a@x", SHORT, reader).await, CredentialState::Pending);
        let joined = {
            let reads = reads.clone();
            tokio::spawn(async move { reads.state("a@x", LONG, || CredentialState::Unclear).await })
        };
        tokio::time::sleep(Duration::from_millis(20)).await;
        answer.send(CredentialState::Refused).unwrap();

        assert_eq!(joined.await.unwrap(), CredentialState::Refused);
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }

    /// Once a read has answered, the next check starts a fresh one: a stale
    /// answer must not stand for the keyring's state now.
    #[tokio::test]
    async fn an_answered_read_is_not_reused() {
        let reads = InFlightReads::default();
        assert_eq!(reads.state("a@x", LONG, || CredentialState::Refused).await, CredentialState::Refused);
        assert_eq!(reads.state("a@x", LONG, || CredentialState::Readable).await, CredentialState::Readable);
    }

    #[tokio::test]
    async fn different_accounts_do_not_share_a_read() {
        let count = Arc::new(AtomicUsize::new(0));
        let (answer, blocked) = gated(&count);
        let reads = InFlightReads::default();

        assert_eq!(reads.state("old@x", SHORT, blocked).await, CredentialState::Pending);
        assert_eq!(reads.state("new@x", LONG, || CredentialState::Readable).await, CredentialState::Readable);
        let _ = answer.send(CredentialState::Readable);
    }

    #[tokio::test]
    async fn a_reader_that_dies_leaves_no_stale_slot() {
        let reads = InFlightReads::default();
        let died = reads
            .state("a@x", LONG, || -> CredentialState { panic!("reader died") })
            .await;
        assert_eq!(died, CredentialState::Unclear);
        assert_eq!(reads.state("a@x", LONG, || CredentialState::Readable).await, CredentialState::Readable);
    }
}
```

Run: `cd native && cargo test --lib token_store::credential_read_tests`
Expected: error de compilación, `InFlightReads` no existe.

- [ ] **Step 4: Implementar `InFlightReads` y `credential_state_within`**

Añadir en `native/src/token_store.rs`, después de `read_credential`:

```rust
/// How long `auth_status` waits for the keyring before calling the credential
/// `Pending`.
///
/// The whole dashboard body hangs on the auth status, so an unanswered unlock
/// prompt must not hold it. The machine answers in about 69 ms (measured) and
/// under 1 ms when the service is down; 3 s is roughly 40 times that plus room
/// for a D-Bus activation start (an estimate, not measured). Past it, the one
/// still to answer is a person, and telling someone mid-typing "waiting for you
/// to unlock" is true, whereas a longer deadline leaves the whole app blank.
pub(crate) const CREDENTIAL_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

type Slot = tokio::sync::watch::Receiver<Option<CredentialState>>;
type Slots = std::sync::Arc<std::sync::Mutex<std::collections::HashMap<String, Slot>>>;

/// At most one keyring read per account at a time.
///
/// A read that outlasts its deadline is not cancelled: the unlock prompt stays
/// answerable, and later checks join the same read instead of starting another
/// one — so pressing "Check again" with the prompt still open does not stack
/// prompts, whatever the keyring would do with two.
#[derive(Default)]
struct InFlightReads {
    slots: Slots,
}

/// Frees an account's slot when its read ends — including by panic, so a dead
/// reader cannot leave every later check joined to a slot nobody will fill.
struct FreeSlot {
    slots: Slots,
    email: String,
}

impl Drop for FreeSlot {
    fn drop(&mut self) {
        self.slots.lock().unwrap_or_else(|p| p.into_inner()).remove(&self.email);
    }
}

impl InFlightReads {
    async fn state<R>(&self, email: &str, timeout: std::time::Duration, read: R) -> CredentialState
    where
        R: FnOnce() -> CredentialState + Send + 'static,
    {
        let mut slot = {
            let mut slots = self.slots.lock().unwrap_or_else(|p| p.into_inner());
            match slots.get(email) {
                Some(slot) => slot.clone(),
                None => {
                    let (tx, rx) = tokio::sync::watch::channel(None);
                    slots.insert(email.to_string(), rx.clone());
                    let free = FreeSlot { slots: self.slots.clone(), email: email.to_string() };
                    tokio::task::spawn_blocking(move || {
                        let state = read();
                        // Free before publishing, so a caller that sees this
                        // answer and asks again starts a fresh read.
                        drop(free);
                        let _ = tx.send(Some(state));
                    });
                    rx
                }
            }
        };
        match tokio::time::timeout(timeout, slot.wait_for(Option::is_some)).await {
            Ok(Ok(state)) => (*state).unwrap_or(CredentialState::Unclear),
            // The reader ended without an answer (it panicked).
            Ok(Err(_)) => CredentialState::Unclear,
            Err(_) => CredentialState::Pending,
        }
    }
}

static CREDENTIAL_READS: std::sync::LazyLock<InFlightReads> =
    std::sync::LazyLock::new(InFlightReads::default);

/// `email`'s credential state, waiting at most `timeout` for the keyring.
pub(crate) async fn credential_state_within(
    email: &str,
    timeout: std::time::Duration,
) -> CredentialState {
    let owned = email.to_string();
    CREDENTIAL_READS.state(email, timeout, move || read_credential(&owned)).await
}
```

Run: `cd native && cargo test --lib token_store`
Expected: PASS, todo `token_store` incluido `credential_read_tests`.

- [ ] **Step 5: Tabla de `auth_status_for` (RED)**

En `native/src/accounts.rs`, `mod tests`: añadir `use crate::token_store::CredentialState;` y
cambiar el cuarto argumento de las llamadas existentes: `true` → `Some(CredentialState::Readable)` y
`false` → `None`. Luego añadir:

```rust
    /// La tabla de la spec. Cada fila, un motivo: Missing manda a iniciar
    /// sesión (la sesión ya no existe); Unreachable, Refused y Pending mandan a
    /// la pantalla del llavero (la sesión sigue guardada); Unclear se queda en
    /// el comportamiento de antes.
    #[test]
    fn the_native_session_follows_what_the_keyring_said() {
        use CredentialState::*;
        let cases = [
            (None, false, None),
            (Some(Readable), true, None),
            (Some(Missing), false, None),
            (Some(Unreachable), false, Some(KeyringProblem::Unreachable)),
            (Some(Refused), false, Some(KeyringProblem::Refused)),
            (Some(Pending), false, Some(KeyringProblem::Pending)),
            (Some(Unclear), true, None),
        ];
        for (credential, authenticated, problem) in cases {
            let status = auth_status_for(AuthEngine::Native, true, true, credential);
            assert_eq!(status.authenticated, authenticated, "{credential:?}");
            assert_eq!(status.keyring_problem, problem, "{credential:?}");
        }
    }

    /// El motor gcloud no lee el llavero de LCC: jamás informa de un problema
    /// del llavero, diga lo que diga el argumento nativo.
    #[test]
    fn the_gcloud_route_never_reports_a_keyring_problem() {
        let status = auth_status_for(AuthEngine::Gcloud, true, true, Some(CredentialState::Refused));
        assert!(status.authenticated);
        assert_eq!(status.keyring_problem, None);
    }
```

Run: `cd native && cargo test --lib accounts`
Expected: error de compilación: `KeyringProblem` no existe, `keyring_problem` no existe, y la firma
de `auth_status_for` no casa.

- [ ] **Step 6: `KeyringProblem`, el campo nuevo, `auth_status_for` y `auth_status`**

En `native/src/accounts.rs`, junto a `AuthStatus`:

```rust
/// Why the keyring kept the active account's sign-in out of reach. Each one
/// gets its own wording on the dashboard, because each is a different fix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyringProblem {
    /// No Secret Service answered.
    Unreachable,
    /// The keyring is locked, or its unlock prompt was dismissed.
    Refused,
    /// No answer within the deadline: an unlock prompt is probably waiting.
    Pending,
}
```

Añadir a `AuthStatus` el campo `pub keyring_problem: Option<KeyringProblem>,`, con un doc comment
que diga: con el motor nativo es la razón por la que `authenticated` es false aunque haya cuenta
activa; con gcloud siempre es `None`.

Sustituir `auth_status_for`:

```rust
fn auth_status_for(
    engine: AuthEngine,
    gcloud_installed: bool,
    gcloud_authenticated: bool,
    native_credential: Option<CredentialState>,
) -> AuthStatus {
    let (authenticated, keyring_problem) = match route(engine) {
        Route::Gcloud => (gcloud_installed && gcloud_authenticated, None),
        Route::Native => match native_credential {
            None => (false, None),
            Some(CredentialState::Readable | CredentialState::Unclear) => (true, None),
            Some(CredentialState::Missing) => (false, None),
            Some(CredentialState::Unreachable) => (false, Some(KeyringProblem::Unreachable)),
            Some(CredentialState::Refused) => (false, Some(KeyringProblem::Refused)),
            Some(CredentialState::Pending) => (false, Some(KeyringProblem::Pending)),
        },
    };
    let gcloud_required = matches!(route(engine), Route::Gcloud);
    AuthStatus { gcloud_installed, authenticated, gcloud_required, keyring_problem }
}
```

Añadir `use crate::token_store::CredentialState;` a los `use` de `accounts.rs`. En `auth_status`,
sustituir la rama `Route::Native` y el nombre de la tupla:

```rust
    let (gcloud_authenticated, native_credential) = match route(engine) {
        Route::Gcloud => (
            gcloud_installed
                && gcloud_call(crate::gcloud::is_gcloud_authenticated).await.unwrap_or(false),
            None,
        ),
        // The index says whether there is an account; only the keyring says
        // whether its sign-in can be used now.
        Route::Native => {
            let active = crate::oauth::store_call(crate::token_store::active_account)
                .await
                .ok()
                .flatten();
            let credential = match active {
                Some(email) => Some(
                    crate::token_store::credential_state_within(
                        &email,
                        crate::token_store::CREDENTIAL_READ_TIMEOUT,
                    )
                    .await,
                ),
                None => None,
            };
            (false, credential)
        }
    };
    auth_status_for(engine, gcloud_installed, gcloud_authenticated, native_credential)
```

Actualizar el doc comment de `auth_status_for`: habla de la credencial, no de `native_has_active`.

Run: `cd native && cargo test --lib accounts && cargo test --lib token_store && cargo build --lib 2>&1 | grep -E "^(warning|error)"`
Expected: tests PASS y ninguna línea de warning/error de `token_store.rs` o `accounts.rs` (el
`dead_code` del Step 2 ha desaparecido).

- [ ] **Step 7: Regenerar el puente y reconstruir los dos lados**

```bash
cd /home/jlopezre/GitHub/LCC
/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
grep -n "rustContentHash" lib/src/bridge/api.dart/frb_generated.dart
grep -n "FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH" native/src/frb_generated.rs
grep -n "enum KeyringProblem\|keyringProblem" lib/src/bridge/api.dart/accounts.dart
cd native && cargo build --lib && cargo build --release --lib
```

Expected: los dos hashes iguales entre sí (anotar el valor); `accounts.dart` con
`enum KeyringProblem { unreachable, refused, pending }` y `final KeyringProblem? keyringProblem;`;
builds sin errores. Si el codegen toca structs ajenos (lo avisa la memoria: `GcpInstanceClientLib`),
revisar el diff de `lib/src/bridge` y arreglar los sitios de llamada antes de seguir.

- [ ] **Step 8: Suite nativa y clippy**

```bash
cd /home/jlopezre/GitHub/LCC && git status --short
cd native && cargo test && cargo clippy --lib --tests 2>&1 | grep -E -A4 "src/(token_store|accounts)\.rs"
```

Expected: la suite completa en verde y ningún aviso de clippy en los dos ficheros.

- [ ] **Step 9: Commit (Rust y puente juntos)**

```bash
git add native/src/token_store.rs native/src/accounts.rs native/src/frb_generated.rs lib/src/bridge/api.dart
git commit -m "feat(auth): auth_status lee la credencial real, con plazo, y dice por qué no se puede usar"
```

---

### Task 3: Dart decide la pantalla desde el estado (función pura)

**Files:**
- Create: `lib/src/features/dashboard_gate.dart`
- Modify: `lib/src/features/gcloud_provider.dart:259-266` (`gcloudStatusProvider`)
- Test: `test/dashboard_gate_test.dart`

**Interfaces:**
- Consumes: `AuthStatus` y `KeyringProblem` de `lib/src/bridge/api.dart/accounts.dart` (Tarea 2).
- Produces:
  - `enum DashboardGate { gcloudRequired, keyring, signIn, ready }`
  - `Map<String, bool> statusMapFor(AuthStatus status)`
  - `KeyringProblem? keyringProblemIn(Map<String, bool> status)`
  - `DashboardGate dashboardGateFor(Map<String, bool> status)`
  - Claves nuevas del mapa: `'keyringUnreachable'`, `'keyringRefused'` y `'keyringPending'`.

- [ ] **Step 1: Tests (RED)**

`test/dashboard_gate_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/accounts.dart';
import 'package:linux_cloud_connector/src/features/dashboard_gate.dart';

AuthStatus _native({required bool authenticated, KeyringProblem? problem}) =>
    AuthStatus(
      gcloudInstalled: false,
      authenticated: authenticated,
      gcloudRequired: false,
      keyringProblem: problem,
    );

void main() {
  group('statusMapFor', () {
    test('each keyring problem survives the trip through the map', () {
      for (final problem in [...KeyringProblem.values, null]) {
        final map =
            statusMapFor(_native(authenticated: false, problem: problem));
        expect(keyringProblemIn(map), problem, reason: '$problem');
      }
    });

    test('keeps the keys the dashboard already reads', () {
      final map = statusMapFor(_native(authenticated: true));
      expect(map['authenticated'], isTrue);
      expect(map['installed'], isFalse);
      expect(map['gcloudRequired'], isFalse);
    });
  });

  group('dashboardGateFor', () {
    // With the keyring out of reach, authenticated is false too. If the
    // sign-in branch came first, the user would be sent to sign in again —
    // which could not store the credential either, while their session is
    // still saved.
    test('a keyring problem comes before signing in', () {
      for (final key in ['keyringUnreachable', 'keyringRefused', 'keyringPending']) {
        expect(
          dashboardGateFor({'authenticated': false, key: true}),
          DashboardGate.keyring,
          reason: key,
        );
      }
    });

    test('an entry gone from the keyring asks to sign in', () {
      expect(dashboardGateFor({'authenticated': false}), DashboardGate.signIn);
    });

    test('a missing gcloud on the gcloud route comes first', () {
      expect(
        dashboardGateFor({
          'gcloudRequired': true,
          'installed': false,
          'authenticated': false,
          'keyringRefused': true,
        }),
        DashboardGate.gcloudRequired,
      );
    });

    test('a readable session is ready', () {
      expect(dashboardGateFor({'authenticated': true}), DashboardGate.ready);
    });
  });
}
```

Run: `flutter test test/dashboard_gate_test.dart`
Expected: FAIL, `dashboard_gate.dart` no existe.

- [ ] **Step 2: Implementar `dashboard_gate.dart`**

```dart
import '../bridge/api.dart/accounts.dart' show AuthStatus, KeyringProblem;

/// What the dashboard body shows, decided from [gcloudStatusProvider]'s map.
enum DashboardGate { gcloudRequired, keyring, signIn, ready }

/// The auth status as the flat map the dashboard reads. The keyring problem
/// travels as three booleans so the map keeps its `Map<String, bool>` shape.
Map<String, bool> statusMapFor(AuthStatus status) {
  final problem = status.keyringProblem;
  return {
    'installed': status.gcloudInstalled,
    'authenticated': status.authenticated,
    'gcloudRequired': status.gcloudRequired,
    'keyringUnreachable': problem == KeyringProblem.unreachable,
    'keyringRefused': problem == KeyringProblem.refused,
    'keyringPending': problem == KeyringProblem.pending,
  };
}

/// The keyring problem carried by [statusMapFor]'s map, if any.
KeyringProblem? keyringProblemIn(Map<String, bool> status) {
  if (status['keyringUnreachable'] == true) return KeyringProblem.unreachable;
  if (status['keyringRefused'] == true) return KeyringProblem.refused;
  if (status['keyringPending'] == true) return KeyringProblem.pending;
  return null;
}

/// Which screen the dashboard shows. The order is the point: a keyring
/// problem comes before "sign in", because with the keyring out of reach
/// `authenticated` is false as well, and signing in again could not store the
/// credential either — the session is still saved.
DashboardGate dashboardGateFor(Map<String, bool> status) {
  if (status['gcloudRequired'] == true && status['installed'] != true) {
    return DashboardGate.gcloudRequired;
  }
  if (keyringProblemIn(status) != null) return DashboardGate.keyring;
  if (status['authenticated'] != true) return DashboardGate.signIn;
  return DashboardGate.ready;
}
```

- [ ] **Step 3: `gcloudStatusProvider` usa `statusMapFor`**

En `lib/src/features/gcloud_provider.dart`, añadir `import 'dashboard_gate.dart';` y sustituir el
cuerpo de `gcloudStatusProvider`:

```dart
final gcloudStatusProvider = FutureProvider<Map<String, bool>>((ref) async {
  return statusMapFor(await checkAuthStatus());
});
```

Añadir al final de su doc comment: "The keyring keys say why a native session with an active
account is not usable; see `dashboardGateFor`."

- [ ] **Step 4: Tests en verde y análisis**

Run: `flutter test test/dashboard_gate_test.dart test/projects_provider_test.dart && flutter analyze lib/src/features/dashboard_gate.dart lib/src/features/gcloud_provider.dart test/dashboard_gate_test.dart`
Expected: PASS, y ningún issue nuevo en esos ficheros.

- [ ] **Step 5: Commit**

```bash
git add lib/src/features/dashboard_gate.dart lib/src/features/gcloud_provider.dart test/dashboard_gate_test.dart
git commit -m "feat(dashboard): el estado de sesión dice si el llavero impide usarla"
```

---

### Task 4: La pantalla del llavero (widget y textos EN/ES)

**Files:**
- Create: `lib/src/features/keyring_problem_screen.dart`
- Modify: `lib/l10n/app_en.arb` y `lib/l10n/app_es.arb` (después de `dashboardCheckAgainButton`)
- Regenerate: `lib/l10n/gen/*` (`flutter gen-l10n`)
- Test: `test/keyring_problem_screen_test.dart`, y `test/es_overflow_test.dart` (entradas nuevas en
  `_dialogs`)

**Interfaces:**
- Consumes: `KeyringProblem` (Tarea 2).
- Produces: `KeyringProblemScreen({required KeyringProblem problem, required VoidCallback onCheckAgain})`.

- [ ] **Step 1: Textos**

`lib/l10n/app_en.arb`, después de `"dashboardCheckAgainButton"`:

```json
  "dashboardKeyringTitle": "Can't read your sign-in from the system keyring",
  "dashboardKeyringUnreachableBody": "LCC could not reach the system keyring. This usually means no Secret Service (GNOME Keyring or KWallet) is running.",
  "dashboardKeyringRefusedBody": "The system keyring did not grant access: it is locked, or the unlock was cancelled.",
  "dashboardKeyringPendingBody": "Waiting for you to unlock the system keyring. If a dialog is asking for your password (it may be behind this window), answer it and then press Check Again.",
  "dashboardKeyringSessionKept": "Your sign-in is still saved; you do not need to sign in again.",
```

`lib/l10n/app_es.arb`, después de `"dashboardCheckAgainButton"`:

```json
  "dashboardKeyringTitle": "No se puede leer tu sesión del llavero del sistema",
  "dashboardKeyringUnreachableBody": "LCC no ha podido contactar con el llavero del sistema. Suele significar que no está en marcha ningún Secret Service (GNOME Keyring o KWallet).",
  "dashboardKeyringRefusedBody": "El llavero del sistema no ha dado acceso: está bloqueado o se canceló el desbloqueo.",
  "dashboardKeyringPendingBody": "Esperando a que desbloquees el llavero del sistema. Si hay un diálogo pidiendo tu contraseña (puede estar detrás de esta ventana), contéstalo y pulsa Comprobar de nuevo.",
  "dashboardKeyringSessionKept": "Tu sesión sigue guardada; no hace falta volver a iniciar sesión.",
```

Run: `flutter gen-l10n`
Expected: `lib/l10n/gen/app_localizations*.dart` con los getters `dashboardKeyring*`.

- [ ] **Step 2: Tests del widget (RED)**

`test/keyring_problem_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/accounts.dart';
import 'package:linux_cloud_connector/src/features/keyring_problem_screen.dart';

Future<void> _pump(WidgetTester tester, KeyringProblem problem,
    {VoidCallback? onCheckAgain}) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: KeyringProblemScreen(
          problem: problem, onCheckAgain: onCheckAgain ?? () {}),
    ),
  ));
}

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .join('\n');

void main() {
  testWidgets('unreachable names the missing service', (tester) async {
    await _pump(tester, KeyringProblem.unreachable);
    expect(_allText(tester), contains('Secret Service'));
  });

  // Measured: a locked keyring whose prompt was dismissed has a Secret Service
  // running. Telling the user to start one would be false.
  testWidgets('refused says locked or cancelled, and never blames the service',
      (tester) async {
    await _pump(tester, KeyringProblem.refused);
    final text = _allText(tester);
    expect(text, contains('locked'));
    expect(text, contains('cancelled'));
    expect(text, isNot(contains('Secret Service')));
  });

  testWidgets('pending says it is waiting and where the dialog may be',
      (tester) async {
    await _pump(tester, KeyringProblem.pending);
    final text = _allText(tester);
    expect(text, contains('Waiting for you to unlock'));
    expect(text, contains('behind this window'));
  });

  testWidgets('every case says the session is still saved', (tester) async {
    for (final problem in KeyringProblem.values) {
      await _pump(tester, problem);
      expect(_allText(tester), contains('still saved'), reason: '$problem');
    }
  });

  testWidgets('Check Again calls back once per press', (tester) async {
    var presses = 0;
    await _pump(tester, KeyringProblem.pending, onCheckAgain: () => presses++);
    await tester.tap(find.text('Check Again'));
    expect(presses, 1);
  });
}
```

Run: `flutter test test/keyring_problem_screen_test.dart`
Expected: FAIL, `keyring_problem_screen.dart` no existe.

- [ ] **Step 3: El widget**

`lib/src/features/keyring_problem_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

import '../bridge/api.dart/accounts.dart' show KeyringProblem;

/// The dashboard body when the active account's sign-in is saved but the
/// system keyring will not hand it over. Each problem gets its own wording,
/// and none claims a cause the app cannot tell apart ("locked, or the unlock
/// was cancelled").
class KeyringProblemScreen extends StatelessWidget {
  const KeyringProblemScreen({
    super.key,
    required this.problem,
    required this.onCheckAgain,
  });

  final KeyringProblem problem;
  final VoidCallback onCheckAgain;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final body = switch (problem) {
      KeyringProblem.unreachable => l10n.dashboardKeyringUnreachableBody,
      KeyringProblem.refused => l10n.dashboardKeyringRefusedBody,
      KeyringProblem.pending => l10n.dashboardKeyringPendingBody,
    };
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline,
                    size: 72, color: Colors.blueGrey.shade300),
                const SizedBox(height: 16),
                Text(
                  l10n.dashboardKeyringTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(body,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 8),
                Text(l10n.dashboardKeyringSessionKept,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onCheckAgain,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.dashboardCheckAgainButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

Run: `flutter test test/keyring_problem_screen_test.dart`
Expected: PASS.

- [ ] **Step 4: La pantalla entra en el test de desbordamiento en español**

En `test/es_overflow_test.dart`, añadir el import de `keyring_problem_screen.dart` y de
`bridge/api.dart/accounts.dart` (`show KeyringProblem`), y estas entradas en `_dialogs`:

```dart
  'KeyringProblemScreen unreachable': () => KeyringProblemScreen(
      problem: KeyringProblem.unreachable, onCheckAgain: () {}),
  'KeyringProblemScreen refused': () => KeyringProblemScreen(
      problem: KeyringProblem.refused, onCheckAgain: () {}),
  'KeyringProblemScreen pending': () => KeyringProblemScreen(
      problem: KeyringProblem.pending, onCheckAgain: () {}),
```

Run: `flutter test test/es_overflow_test.dart`
Expected: PASS en los 3 tamaños × 3 casos nuevos, y todo lo que ya pasaba sigue pasando.

- [ ] **Step 5: Commit**

```bash
git add lib/src/features/keyring_problem_screen.dart lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen test/keyring_problem_screen_test.dart test/es_overflow_test.dart
git commit -m "feat(dashboard): pantalla para cuando el llavero no entrega la sesión"
```

---

### Task 5: El panel usa la decisión y la pantalla

**Files:**
- Modify: `lib/main.dart:474-560` (rama `data:` de `DashboardScreen`)

**Interfaces:**
- Consumes: `dashboardGateFor`, `keyringProblemIn` y `DashboardGate` (Tarea 3), y
  `KeyringProblemScreen` (Tarea 4).

- [ ] **Step 1: Cambiar las dos condiciones por la decisión e insertar la rama del llavero**

En `lib/main.dart`, añadir los imports de `src/features/dashboard_gate.dart` y de
`src/features/keyring_problem_screen.dart`. En `data: (status) {`:
- Primera línea: `final gate = dashboardGateFor(status);`.
- `if (status['gcloudRequired'] == true && status['installed'] != true) {` pasa a ser
  `if (gate == DashboardGate.gcloudRequired) {`. El cuerpo no cambia.
- Justo después del cierre de ese `if`, insertar:

```dart
          if (gate == DashboardGate.keyring) {
            return KeyringProblemScreen(
              problem: keyringProblemIn(status)!,
              onCheckAgain: () {
                // The status, not the project list: invalidating the status
                // re-arms Riverpod's retries; invalidating projectsProvider
                // alone gets one attempt and no retries (measured).
                // With the unlock prompt still open, this shows the spinner
                // for about 3 s and comes back to the same Pending screen:
                // the check joins the read still waiting on that prompt
                // instead of opening another one. That is correct.
                ref.invalidate(gcloudStatusProvider);
                ref.invalidate(multiProjectProvider);
              },
            );
          }
```

- `if (status['authenticated'] != true) {` pasa a ser `if (gate == DashboardGate.signIn) {`. El
  cuerpo no cambia.

- [ ] **Step 2: Análisis y suite Dart**

```bash
cd /home/jlopezre/GitHub/LCC && git status --short
flutter analyze lib/main.dart lib/src/features
flutter test
```

Expected: ningún issue nuevo en `lib/main.dart`, y la suite completa en verde. Si algún test falla
y no se entiende, NO llamarlo "preexistente" sin medirlo en un worktree limpio en HEAD (con
`cargo build --lib` hecho dentro del worktree antes).

- [ ] **Step 3: Commit**

```bash
git add lib/main.dart
git commit -m "feat(dashboard): el panel muestra el problema del llavero antes que el inicio de sesión"
```

---

### Task 6: Mutaciones, entrega del puente y QA real

- [ ] **Step 1: Mutaciones (cada una debe poner algún test en rojo)**

Aplicar de una en una, pasar el test indicado y restaurar:

| # | Mutación | Test que debe caer |
|---|---|---|
| M1 | `classify_credential`: `NoStorageAccess` → `Unreachable` | `classify_credential_names_each_outcome` |
| M2 | `keyring_backend_error`: texto de `NoStorageAccess` igual al de `PlatformFailure` | `a_locked_keyring_is_not_reported_as_a_missing_service` |
| M3 | `InFlightReads::state`: no insertar la ranura (siempre lectura nueva) | `a_second_check_while_waiting_joins_the_same_read` |
| M4 | `timeout` → `wait_for` sin plazo | `a_read_that_outlasts_the_deadline_is_pending` (se cuelga: pasar con `timeout 60`) |
| M5 | Quitar `FreeSlot` (no liberar la ranura) | `an_answered_read_is_not_reused` o `a_reader_that_dies_leaves_no_stale_slot` |
| M6 | Clave de la ranura fija (`"x"`) en vez de `email` | `different_accounts_do_not_share_a_read` |
| M7 | `auth_status_for`: `Missing` → `Some(KeyringProblem::Refused)` | `the_native_session_follows_what_the_keyring_said` |
| M8 | `auth_status_for`: `Unclear` → `(false, None)` | `the_native_session_follows_what_the_keyring_said` |
| M9 | `dashboardGateFor`: rama `signIn` antes que `keyring` | `a keyring problem comes before signing in` |
| M10 | `statusMapFor`: `keyringPending` siempre false | `each keyring problem survives the trip through the map` |
| M11 | `KeyringProblemScreen`: `refused` usa el texto de `unreachable` | `refused says locked or cancelled…` |

Anotar las que queden en verde. Las previstas: el cableado de `auth_status` (Rust) y el de
`main.dart` (Dart) solo los cubre la QA. Si queda en verde alguna que no esté prevista, escribir en
el código qué no cubre.

- [ ] **Step 2: Entregar los hashes del puente**

Mandar a la otra sesión los dos hashes (Dart `rustContentHash` y Rust
`FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH`), los commits de las Tareas 1–5 y la lista de mutaciones.
Esa sesión verifica y monta la .43.

- [ ] **Step 3: QA — sin Secret Service**

Con la .43: `DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent <binario>`.
Expected: pantalla *Unreachable*. En `app.log` (ojo, UTC), 0 líneas "Listing GCP projects" y 0
"Listing instances" en esa ejecución.

- [ ] **Step 4: QA — llavero bloqueado**

Bloquear con
`busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service Lock ao 1 /org/freedesktop/secrets/collection/login`
y arrancar la app:
- **Diálogo sin tocar:** a los 3 s o menos, pantalla *Pending*; pestañas, Ajustes y gestor de túneles
  usables. Desbloquear en el diálogo y pulsar Comprobar de nuevo: carga los proyectos sin reiniciar.
- **Botón pulsado con el diálogo aún abierto (la razón de ser de la lectura única):** bloquear,
  arrancar y NO tocar el diálogo. Esperar a *Pending* y pulsar Comprobar de nuevo dos o tres veces.
  Expected: sigue habiendo UN solo diálogo de desbloqueo, nunca dos. Luego contestarlo y pulsar una
  vez más: entra.
  Qué verá quien pulse, y es CORRECTO: el cuerpo muestra la rueda unos 3 s y vuelve la misma
  pantalla *Pending*. La comprobación se engancha a la lectura que sigue esperando al diálogo, y al
  agotar el plazo vuelve a decir *Pending*. No es un botón que "no hace nada"; no "arreglarlo".
- **Volver a bloquear, arrancar y cancelar el diálogo:** pantalla *Refused*. Pulsar Comprobar de
  nuevo: vuelve a pedir la contraseña; al desbloquear, entra.
- Al terminar, dejar el llavero desbloqueado y comprobarlo (`Locked` = `false`).

- [ ] **Step 5: QA — arranque en frío con el llavero sano (Review Focus 1)**

Cerrar la app, arrancarla con el llavero desbloqueado y la sesión normal.
Expected: el panel normal, sin *Pending* en ningún momento. Si aparece *Pending*, el plazo se queda
corto: parar y replantearlo con el dato.
