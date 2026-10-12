# QA manual — SG-D / D3: adquisición de token nativa

El canje real necesita Google y un navegador, así que no es testeable en CI.
Ejecutar desde `native/`.

Prerrequisito: cuenta añadida como test user en la pantalla de consentimiento, y
un Secret Service vivo (GNOME Keyring o KWallet).

- [ ] **Primera ejecución**: `LCC_AUTH_ENGINE=native cargo run --example auth_native` abre el navegador, completas el consentimiento, e imprime `✓ Session ready for: <tu email>`, `engine: Native` y un prefijo del access token.
- [ ] **Segunda ejecución** (la prueba clave): el mismo comando **NO abre el navegador** y vuelve a imprimir el token. Eso demuestra que el refresh token guardado en el keyring se está usando.
- [ ] **La cuenta quedó registrada**: `cat ~/.local/share/lightweight_cloud_connector/oauth_accounts.json` muestra tu email en `accounts` y en `active` — y ningún token.
- [ ] **El flag apagado no cambia nada**: `cargo run --example auth_native` **sin** la variable sigue funcionando vía el camino de siempre, y la app normal (sin la variable) lista proyectos e instancias como antes.
- [ ] **La app con el flag**: lanzar LCC con `LCC_AUTH_ENGINE=native` lista proyectos e instancias correctamente, **sin** que intervenga gcloud (comprobable con `ps aux | grep 'gcloud auth'` mientras navegas: no debe aparecer).
- [ ] **Independencia real de gcloud**: renombrar temporalmente `~/.config/gcloud/application_default_credentials.json` (o confirmar que ya no existe), ejecutar `LCC_AUTH_ENGINE=native cargo run --example auth_native` de punta a punta con éxito, y luego restaurar el archivo. Esta es la única comprobación que demuestra de verdad que el camino nativo no depende de gcloud.
- [ ] **Recuperación**: borrar el secreto del keyring desde el gestor de contraseñas del escritorio (Seahorse en GNOME, KWalletManager en KDE) — **no** editar `oauth_accounts.json` a mano — y volver a ejecutar el ejemplo → detecta que la cuenta activa ya no tiene sesión utilizable y abre el navegador de nuevo, sin quedarse colgado. (`cargo test --lib token_store -- --ignored` NO sirve para esto: opera sobre una cuenta de prueba propia y restaura el índice original al terminar, así que tu cuenta real queda intacta.)
- [ ] **Sin secretos en la salida**: ni el refresh token ni el access token completo aparecen en consola (solo un prefijo de 12 caracteres).
