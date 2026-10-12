# QA manual — SG-D / D1: núcleo OAuth

El flujo necesita navegador y cuenta Google real, así que no es testeable en CI.
Ejecutar desde `native/`: `cargo run --example oauth_login`

Requisito previo: la cuenta debe estar añadida como **test user** en la pantalla
de consentimiento (estado *Testing*) del proyecto dueño del client OAuth.

- [ ] La consola imprime la URL de autorización y el puerto local (`Sign in at (listening on 127.0.0.1:<puerto>):`) **antes** de que se abra el navegador. Útil si `xdg-open` no está disponible (SSH, contenedor mínimo): la URL se puede pegar a mano, y el puerto sirve para el ítem de `ss -ltnp` más abajo.
- [ ] Se abre el navegador en la pantalla de consentimiento de Google.
- [ ] La pantalla muestra los permisos esperados (Google Cloud + email) y el nombre de la app.
- [ ] Tras aceptar, el navegador muestra "Signed in to Lightweight Cloud Connector" y se puede cerrar la pestaña.
- [ ] La consola imprime el **email correcto** de la cuenta usada.
- [ ] La consola indica `refresh token: received`. (Si Google no lo entrega, no aparece `refresh token: MISSING`: `exchange_code` falla duro y el proceso termina con `✗ Sign-in failed: Token response has no refresh_token`, código de salida ≠0 — esa es la señal real a esperar en ese caso, no una línea "MISSING" en consola.)
- [ ] **Segundo login** con la misma cuenta: vuelve a indicar `refresh token: received` (esto valida `prompt=consent`).
- [ ] **Cancelar** el consentimiento en el navegador: el ejemplo termina con un error que menciona `access_denied`, sin quedarse colgado.
- [ ] **Timeout del login en el navegador**: bajar temporalmente `REDIRECT_TIMEOUT` en `native/src/oauth.rs` (p. ej. a 10 s), recompilar (`cargo build --example oauth_login`) y lanzar el ejemplo sin completar el login → tras ~10 s el proceso termina con `✗ Sign-in failed: Timed out waiting for the browser sign-in to complete`, y `ss -ltnp | grep 127.0.0.1` ya no muestra el listener. (Alternativa sin tocar código: esperar los 300 s completos con el valor real.) Revertir el cambio de `REDIRECT_TIMEOUT` antes de continuar.
- [ ] **Timeout del canje de tokens**: tras aceptar el consentimiento en el navegador, cortar la red antes de que la app cambie el `code` por tokens → el ejemplo falla en ≤30 s con `✗ Sign-in failed: Token request failed: ...`, sin colgarse.
- [ ] Ni el refresh token, ni el verifier PKCE, ni el access token completo aparecen en la salida (solo "received" y un prefijo corto del access token; el `state` sí aparece, pero solo como parte de la URL de autorización impresa arriba — no es un secreto de larga vida).
- [ ] Tras cerrar el ejemplo, el puerto local queda libre (`ss -ltnp | grep 127.0.0.1` no muestra el listener; usar el puerto impreso al inicio para confirmar cuál era).
