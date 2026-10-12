# QA manual — SG-D / D2: almacén de tokens

Los tests unitarios cubren la lógica del índice sin tocar disco ni keyring.
Esto verifica lo que solo se ve contra el keyring real.

Prerrequisito: sesión de escritorio con un Secret Service vivo (GNOME Keyring o KWallet).

- [ ] **Round-trip real**: `cd native && cargo test --lib token_store -- --ignored` pasa (guarda, lee, lista y borra contra el keyring del sistema).
- [ ] **El índice no contiene secretos**: tras el round-trip, `cat ~/.local/share/lightweight_cloud_connector/oauth_accounts.json` muestra solo emails y `active` — ninguna cadena que parezca un refresh token.
- [ ] **El secreto sí está en el keyring**: durante una ejecución que haya guardado una cuenta, `secret-tool search service linux-cloud-connector` (paquete `libsecret-tools`) lista una entrada cuyo nombre incluye `oauth::`. Tras el borrado del round-trip ya no aparece.
- [ ] **Sin keyring, error accionable**: en una sesión sin Secret Service — por ejemplo `env -u DBUS_SESSION_BUS_ADDRESS cargo test --lib token_store -- --ignored` — el test falla en el `save_account("...").expect("save")` inicial, con un mensaje que contiene la frase "the sign-in cannot be saved" y menciona GNOME Keyring o KWallet, **no** con un genérico "no encontrado" ni con "No stored session" (esa frase es solo para una cuenta que nunca se guardó). Y el JSON del índice sigue sin secretos.
- [ ] **La cuenta activa sobrevive al reinicio**: el fichero índice conserva `active` entre ejecuciones (se comprueba leyendo el JSON antes y después).
