# SG-E — QA manual del cierre (Doctor nativo, motores visibles, documentación honesta)

**Fecha:** 2026-08-26
**Rama:** `27H1-Preview`
**Spec:** [SG-E — Cierre](../specs/2026-08-25-sge-cleanup-design.md)
**Plan:** [SG-E — Cierre](2026-08-25-sge-cleanup.md)

El criterio de corte de SG-E son los ítems **1, 2, 3 y 5**. Los cuatro: el 1 prueba
que Doctor ya no castiga a quien no tiene gcloud, el 2 que la escotilla sigue
diagnosticándose, el 3 que Doctor detecta el fallo que D2 no detectó, y el 5 que
los selectores nuevos no son decorativos.

Cada ítem nombra **su evidencia**. Un ítem sin la evidencia que pide no está
verde, está sin ejecutar.

## Antes de empezar

El log rota **en UTC** y usted está en UTC-4, así que una reproducción de la tarde
puede haber caído en el fichero del día siguiente. Y compruebe qué binario está
ejecutando: la build instalada en `/usr/lib` puede tener semanas. Ajustes tiene
que mostrar la build que acaba de compilar.

---

## 1. Doctor entero en verde sin gcloud

Sandbox de `bwrap` con `$HOME/google-cloud-sdk`, el SDK del sistema y
`~/.config/gcloud` enmascarados. **No `chmod`**: esa receta dio dos falsos verdes
en el QA de D4. `$HOME/google-cloud-sdk` es obligatoria: `gcloud_bin::resolve()`
la prueba **primero**, y omitirla deja el sandbox sin enmascarar nada en una
máquina con la instalación por tarball.

- [ ] `ls /proc/$P/root/usr/bin/gcloud` no existe, tomando `$P` del PID **sandboxeado** — el que tiene distinto `/proc/$P/ns/mnt` que su shell.
- [ ] **Ninguna fila en rojo.**
- [ ] Las tres filas de gcloud —CLI instalado, cuenta activa, credenciales ADC— en `SKIP` con su motivo, y ese motivo **nombra el motor**, no la ausencia de gcloud. Compruébelo también **fuera del sandbox, en una máquina que sí tiene gcloud**: dentro del sandbox no hay gcloud, así que un motivo falso del tipo "gcloud CLI not installed" sería cierto por accidente y este ítem no lo cazaría.
- [ ] Las tres filas nativas en verde: **LCC Credential Store**, **LCC Account Index**, **LCC Session**.
- [ ] **Las seis comprobaciones de API se EJECUTAN**: proyecto accesible, API de Compute, API de IAP, regla de firewall de IAP, estado de la VM y agente invitado. Ninguna en `SKIP` con motivo de gcloud.
- [ ] Ninguna fila en `SKIP` ofrece botón de **Corregir**.

Ese penúltimo punto es el que destapó la revisión de la tarea 9: la verja exigía
que la fila de la cuenta de gcloud pasara, y bajo el motor nativo esa fila es
`Skipped`, así que las seis se saltaban en una instalación perfecta y el panel se
veía bien por no haber preguntado nada. Si vuelven a salir en `SKIP` diciendo
"gcloud not authenticated", el arreglo se ha perdido.

**Evidencia:** la salida de `/proc/$P/root/…` y `/proc/$P/ns/mnt`, más la captura del panel.

## 2. Doctor con el motor gcloud

Ajustes → Método de inicio de sesión → *Usar el CLI de gcloud*, con sesión de CLI válida.

- [ ] Las filas de gcloud vuelven a `Pass`/`Fail`.
- [ ] Las tres filas nativas pasan a `SKIP`.
- [ ] **Las seis comprobaciones de API se EJECUTAN también aquí.** El ítem 1 prueba la mitad nativa de esa verja; sin esto, la mitad de gcloud queda sin probar y podría haberse roto al arreglar la otra.

**Evidencia:** la captura del panel. Es la mitad que evita que la escotilla se pudra.

## 3. El llavero caído se ve

Sesión sin Secret Service (sin GNOME Keyring ni KWallet).

- [ ] La fila **LCC Credential Store** en rojo, con el mensaje que nombra el Secret Service.
- [ ] **NO** un Doctor entero en verde.
- [ ] **Inicie sesión ANTES de tumbar el llavero**, de modo que el índice tenga al menos una cuenta. Con el índice vacío la fila no recorre nada y sale verde diciendo `Consistent(0)`, así que el ítem pasaría sin haber comprobado nada.
- [ ] La fila **LCC Account Index** dice que no se puede saber, y **no** inventa cuentas huérfanas.

**Evidencia:** la captura. Éste es el ítem que D2 no tuvo: pasó su QA en verde compilando contra el *mock* del crate y sin persistir nada.

## 4. Ninguna cuenta no es un token roto

Con el almacén nativo vacío (sin haber iniciado sesión nunca).

- [ ] La fila **LCC Session** dice que no hay ninguna cuenta iniciada, en **amarillo**.
- [ ] **NO** un fallo de refresco en rojo.

**Evidencia:** el texto literal de la fila.

## 5. Los tres selectores surten efecto sin reiniciar

**Lance la app con `RUST_LOG=debug`.** La línea que nombra el motor de auth es de
nivel `debug` (`gcp_rest_client.rs:195`) y con el filtro por defecto (`info`) no
aparece: sin esto, el ítem de auth no tiene evidencia posible y usted acabaría
mirando la pantalla, que es el método que produjo tres falsos verdes.

- [ ] **Cierre el túnel que hubiera abierto a ese `instancia:puerto`** antes de cambiar de motor. `tunnel.rs:200-212` devuelve un túnel ya abierto **antes** de resolver el motor y sin registrar nada: reabrir el mismo destino tras el cambio no ejercita nada, y la línea idéntica de la pasada anterior sigue en el log esperando a que la confunda.
- [ ] Cambie el **motor de túnel** en Ajustes → Avanzado y abra un túnel **nuevo**. Evidencia: la línea de túnel establecido lleva `engine="gcloud"` (o `"native"`), con marca de tiempo posterior al cambio.
- [ ] Cambie el **motor de reenvío SSH**, cierre el reenvío previo y abra uno nuevo. Misma evidencia.
- [ ] Cambie el **motor de auth** y liste proyectos. Evidencia: la línea `debug` que nombra el motor, en esa pasada.

**La UI no sirve como evidencia.** Dos rutas que producen el mismo resultado en pantalla no se distinguen mirando la pantalla, y así se dieron por buenas tres pruebas que iban por la ruta equivocada.

## 6. Escribir una ranura no borra las otras

- [ ] Cambie el motor de túnel, luego el de auth, luego el de reenvío SSH.
- [ ] Abra `engine.json` en el directorio de datos.

**Evidencia:** las **tres** claves presentes con los valores esperados. Cada escritura reescribe el fichero entero, así que este ítem prueba que la lectura-modificación-escritura funciona.

## 7. El entorno sigue mandando en las tres

- [ ] Con `tunnel_engine` en `native` dentro del fichero, lance con `LCC_TUNNEL_ENGINE=gcloud`.
- [ ] El bloque **Avanzado** avisa de la anulación y nombra **`LCC_TUNNEL_ENGINE`** — no `LCC_AUTH_ENGINE`.
- [ ] El log confirma cuál se usó de verdad.
- [ ] Repítalo con `LCC_SSH_FORWARD_ENGINE`.

**Evidencia:** el texto del aviso y la línea del log. Que el aviso nombre la variable correcta es un arreglo de esta misma tanda; antes decía siempre `LCC_AUTH_ENGINE`.

## 8. Un remedio de administración ofrece salida sin gcloud

Provoque una fila de administración en rojo — por ejemplo con la API de IAP deshabilitada, o una VM apagada.

- [ ] El remedio **conserva** su comando `gcloud …`.
- [ ] Y sus detalles llevan además la ruta de la consola.
- [ ] **La URL se puede usar**: seleccionar y copiar, o abrir. Un enlace que solo se puede leer no es una salida para quien no tiene gcloud, y este ítem pasaba verde con la URL inservible.
- [ ] **El botón de Corregir de una VM apagada arranca la VM sin gcloud.** Es el único botón de Corregir que hay aparte de reautenticar, y llegó a esta tanda invocando gcloud.

**Evidencia:** el texto de la fila con las dos rutas, el portapapeles, y la VM arrancada.

## 9. El README no afirma nada que la app no haga

- [ ] Léalo entero, en inglés y en español.
- [ ] gcloud aparece como **opcional**, con una frase que diga para qué sirve todavía.
- [ ] No hay ninguna instrucción de iniciar sesión con `gcloud auth application-default login`.
- [ ] La descripción del túnel no promete un *fallback* automático a gcloud.

**Evidencia:** la lectura completa.

---

## Deuda conocida que este QA no cubre

- Dos escrituras concurrentes de ranuras distintas siguen siendo último-en-escribir-gana: el fichero temporal ya es por ranura, pero ambas leen y reescriben el mismo `engine.json`.
- El test que protege el cableado accesor→constante en `tunnel.rs` es parcial: caza una constante equivocada, no un accesor cableado a la otra. Está dicho en un comentario sobre el propio test.
- No hay tests de Dart para la capa de consentimiento de SSH.
- `log_out_all` aborta en el primer borrado que falle.
