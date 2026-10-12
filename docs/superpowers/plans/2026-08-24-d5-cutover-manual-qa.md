# D5 — QA manual del cutover (nativo por defecto, gcloud como escotilla)

**Fecha:** 2026-08-25
**Rama:** `27H1-Preview`
**Spec:** [D5 — Cutover](../specs/2026-08-24-d5-cutover-design.md)
**Plan:** [D5 — Cutover](2026-08-24-d5-cutover.md)

El criterio de corte de D5 tiene **dos mitades** y ninguna es opcional. La primera
(ítem 2) prueba que LCC ya no necesita gcloud. La segunda (ítems 4 y 5) prueba que
la escotilla que pidieron los usuarios sigue siendo real. Sin la segunda, D5
entrega una opción que parece soportada y no lo está.

Cada ítem nombra **su evidencia**. Un ítem sin la evidencia que pide no está
verde, está sin ejecutar. Tres sub-proyectos de esta misma iniciativa —D2, D3 y
SG-B— pasaron el QA en verde estando rotos, y siempre por lo mismo: el QA no
ejercitó el camino real.

## Antes de empezar

El log rota **en UTC** y usted está en UTC-4, así que una reproducción de la
tarde puede haber caído en el fichero del día siguiente. Y la app carga
`native/target/release/libnative.so`: si tiene una build instalada en
`/usr/lib`, asegúrese de cuál está ejecutando antes de sacar conclusiones de un
log.

---

## 1. El defecto es nativo

Instalación limpia, o `engine.json` borrado, y **sin** `LCC_AUTH_ENGINE` en el
entorno.

- [ ] Ajustes → Método de inicio de sesión muestra **"Que LCC inicie sesión"** seleccionado.
- [ ] El log no contiene ninguna invocación de gcloud durante el arranque.

**Evidencia:** la captura de Ajustes y el log del arranque.

## 2. Primera mitad del corte — nativo con gcloud inalcanzable

Monte el sandbox con **`bwrap`, no con `chmod`**. La receta de `chmod` dio **dos
falsos verdes** en el QA de D4: el túnel se creó 34 y 27 segundos *después* de
que se restaurara el bit de ejecución. Enmascare las tres rutas:

- `$HOME/google-cloud-sdk` — `gcloud_bin::resolve()` la prueba **primero**, y
  omitirla hace que el sandbox no enmascare nada en una máquina con la
  instalación por tarball.
- el SDK del sistema (`/usr/lib/google-cloud-sdk`, `/snap/bin`, `/usr/bin`…)
- `~/.config/gcloud`

- [ ] `ls /proc/$P/root/usr/bin/gcloud` no existe, tomando `$P` del PID **sandboxeado** — el que tiene distinto `/proc/$P/ns/mnt` que su shell. Comprobarlo sobre el PID equivocado es cómo se veían verdes los dos falsos verdes.
- [ ] Login.
- [ ] Gestión de cuentas: añadir, cambiar de activa, quitar.
- [ ] Lista de proyectos e instancias.
- [ ] Un túnel IAP.
- [ ] Un reenvío SSH.

**Evidencia:** la salida de `/proc/$P/root/…` y de `/proc/$P/ns/mnt`, más el log
con `engine="native"` en las líneas de túnel y reenvío.

## 3. El aviso sale una vez, y solo a quien le tocó

- [ ] Con el flag sin poner y sin elección explícita de motor: **sale**.
- [ ] Tras cerrarlo y reiniciar: **no vuelve**.
- [ ] Con una elección explícita hecha antes en Ajustes: **no sale nunca**.

**Evidencia:** las tres observaciones.

**Una pregunta abierta para usted, no un fallo:** una **instalación nueva**
cumple las dos condiciones (flag sin poner + sin elección explícita), así que un
usuario que estrena LCC verá el aviso — incluida la frase "sus cuentas de gcloud
siguen ahí" cuando no tiene ninguna. El spec define la condición con dos
términos y no le añadí un tercero: los discriminadores posibles (preguntar a
gcloud al arrancar) cuestan latencia o rompen el ítem 2. Mírelo y decida si
molesta lo suficiente como para afinarlo.

## 4. Segunda mitad del corte — la escotilla viva

Seleccione **"Usar el CLI de gcloud"** en Ajustes, con una sesión de CLI válida.

- [ ] Lista de cuentas.
- [ ] Cambio de cuenta activa. **La evidencia NO es el mensaje de la app**: es la insignia de ACTIVA moviéndose, o `gcloud config get-value account`. El snackbar de éxito salía aunque el cambio fallara, y aunque eso ya está arreglado, un ítem que se cree su propio mensaje no prueba nada.
- [ ] Proyectos e instancias, con el log mostrando `auth print-access-token` **en esa misma pasada**. Sin esa línea el ítem puede salir verde con un token cacheado del motor anterior: si las dos cuentas son la misma persona, los datos parecen correctos.
- [ ] **Un túnel IAP bajo el motor gcloud.** El ítem 2 prueba un túnel bajo nativo y este no tenía su gemelo, pese a que el criterio de corte del spec dice "tokens **y túneles**". Es justo donde vivía el fallo del cliente cacheado por proceso.

**Evidencia:** el log mostrando la ruta de gcloud, la línea de `print-access-token`, y el túnel establecido.

## 5. La escotilla dice qué hacer cuando caduca

Con el motor gcloud y la sesión del CLI caducada — `gcloud auth revoke --all` en
su terminal —, intente listar.

- [ ] El mensaje **nombra `gcloud auth login`**.

Un error genérico es un **fallo del ítem**. Ese fallo exacto se leyó como "no
autentica" el 2026-08-19 y costó una sesión entera de diagnóstico.

**Evidencia:** el texto del mensaje, literal.

## 6. Añadir y quitar cuenta bajo el motor gcloud

- [ ] "Añadir cuenta" abre el diálogo con `gcloud auth login`.
- [ ] "Quitar cuenta" abre el diálogo con `gcloud auth revoke <la cuenta>`.
- [ ] El botón de copiar deja el comando correcto en el portapapeles, y **lo confirma en el propio botón** (icono de check y "Copiado").
- [ ] Ejecutado el comando en otra terminal, "Ya lo ejecuté — actualizar" relee la lista **sin reiniciar**.

**Evidencia:** el contenido del portapapeles y la lista antes y después.

## 7. Doctor

- [ ] Bajo el motor **nativo**: las tres filas de gcloud —CLI instalado, cuenta activa y **credenciales ADC**— en `SKIP` con su motivo, y **ninguna en rojo por gcloud**. La fila de ADC importa: antes le sugería a un usuario sin gcloud que ejecutara `gcloud auth application-default login`.
- [ ] Ninguna fila en `SKIP` ofrece botón de **Corregir**.
- [ ] Bajo el motor **gcloud**: `Pass`/`Fail` como siempre.
- [ ] Ninguna fila sugiere un comando de gcloud bajo el motor nativo, **incluida la de "Proyecto accesible"**, que solo enseña su remedio cuando la obtención del token falla — así que hay que provocarla, no basta con mirar una máquina sana.
- [ ] Bajo el motor **nativo**, el log de la pasada de Doctor no contiene ninguna invocación de gcloud. Las filas salían en `SKIP` pero el sondeo se ejecutaba igual; ahora solo se sondea en el motor que mira la respuesta.

**Evidencia:** las dos capturas del panel y el log de la pasada bajo nativo.

## 8. El entorno sigue mandando sobre el fichero

Con `engine.json` diciendo `gcloud`, lance con `LCC_AUTH_ENGINE=native`.

- [ ] El comportamiento es **nativo**, y el log lo confirma.
- [ ] Ajustes muestra la **elección almacenada** (gcloud), no la efectiva.

- [ ] El selector **avisa de que el entorno manda** y nombra el motor realmente en vigor.

La variable gana a propósito: es la escotilla de diagnóstico. Lo que no puede
pasar es que usted cambie el selector, vea moverse el radio, y no cambie nada
sin que nadie se lo diga — y quien corre este QA tiene la variable puesta por
definición.

**Este ítem protege el propio método de QA.** Si el fichero pudiera ganarle al
entorno, el ítem 2 —que se lanza precisamente con la variable puesta— estaría
probando algo distinto de lo que cree.

---

## Deuda conocida que este QA no cubre

- No hay tests de Dart para la capa de consentimiento de SSH, que ya tiene cuatro puntos de llamada.
- No hay forma de revertir por UI un rechazo deliberado del consentimiento.
- `log_out_all` aborta en el primer borrado que falle y deja las cuentas posteriores sin quitar. El usuario ve el error real, no un "sesión cerrada" falso.
- Los errores no clasificados salen como `AnyhowException(...)` en crudo. Es el patrón de toda la app, no una regresión de D5.
