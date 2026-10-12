# D5 — Cutover: nativo por defecto, gcloud como escotilla (spec de diseño)

**Fecha:** 2026-08-24
**Rama:** `27H1-Preview`
**Sub-proyecto:** D5 de **SG-D**, cierre de la iniciativa de salida de `gcloud`
**Depende de:** D0–D4 ✔, SP-1 ✔, SP-2 ✔
**Roadmaps:** [SG-D](2026-08-12-sgd-oauth-roadmap.md) · [salida de gcloud](2026-08-12-gcloud-removal-roadmap.md)

## Qué es D5 después de la decisión del 2026-08-21

Las pruebas con usuarios pidieron **nativo por defecto y gcloud disponible**. La
[opción B](2026-08-12-gcloud-removal-roadmap.md) adoptada dice: LCC usa gcloud si está
autenticado y **nunca invoca su auth**; si la sesión del CLI caduca, la renueva el usuario.

Eso convierte D5 en un sub-proyecto pequeño: **cambiar el defecto, sacar el selector a
Ajustes, y retirar solo las invocaciones de auth**. No es "quitar gcloud".

## Dos correcciones al roadmap (importantes, porque cambian qué se borra)

Al reescribir el roadmap tras la decisión, apliqué "quitar cosas de gcloud" más ancho de
lo que la decisión permite. Dos frases suyas son incorrectas y este spec las anula:

**1. "Retirar `add|remove|list|switch_gcloud_account`".** Falso para `list` y `switch`.
Si alguien selecciona el motor gcloud, LCC saca sus tokens de gcloud — así que necesita
**listar las cuentas de gcloud y cambiar la activa**, o el motor no sirve para nada.
Solo `add` (`gcloud auth login`) y `remove` (`gcloud auth revoke`) son invocaciones de
auth, y esas sí se van.

**2. "Quitar la dependencia del fichero ADC".** Falso. El ADC **pertenece al motor
gcloud**: `token_from_adc_refresh` sigue alcanzable por esa ruta
(`native/src/gcp_rest_client.rs:181`), y su verja de existencia
(`gcp_rest_client.rs:52-70`) ya se salta bajo el motor nativo desde D3. Quitarlo
mutilaría la escotilla.

El patrón compartido —una regla general aplicada sin comprobar caso por caso— es el
mismo que produjo las tres afirmaciones falsas que la revisión final de SP-1 encontró.

## Qué se borra y qué se queda

| | Destino |
|---|---|
| `gcloud::execute_login` y su envoltorio `api::gcloud_login` | **Borrar** |
| `gcloud::execute_logout` y su envoltorio | **Borrar** |
| Brazo `Route::Gcloud` de `accounts::add` (`gcloud auth login`) | **Borrar**, sustituido por el diálogo de instrucción |
| Brazo `Route::Gcloud` de `accounts::remove` (`gcloud auth revoke`) | **Borrar**, ídem |
| `gcloud::list_gcloud_accounts_async` | **Se queda** — sin ella el motor gcloud no lista nada |
| `gcloud::switch_gcloud_account_async` | **Se queda** — ídem para cambiar de cuenta |
| `gcloud::get_gcloud_account` | **Se queda** |
| Token por `print-access-token` y `token_from_adc_refresh` | **Se quedan** |
| Verja del fichero ADC (`gcp_rest_client.rs:52`) | **Se queda**, ya condicionada al motor |
| `is_gcloud_installed` / `is_gcloud_authenticated` | **Se quedan** — Doctor y `auth_status` |

Criterio para decidir: **¿esto invoca la auth de gcloud, o solo la lee?** Lo que la
invoca se va; lo que la lee se queda.

## El selector del motor

Hoy `auth_engine()` (`native/src/oauth.rs:49`) lee **solo** `LCC_AUTH_ENGINE`. Con el
selector en Ajustes, Rust necesita conocer una preferencia persistida.

**Rust posee el fichero.** `engine.json` junto a `oauth_accounts.json`, en
`app_dirs::migrated_app_dir(dirs::data_local_dir())`, con una sola clave —
`{"auth_engine": "native" | "gcloud"}`. Dart lo escribe y lo lee **por el bridge**, de
modo que hay **una sola fuente de verdad** y el selector de Ajustes no duplica el estado
en `SharedPreferences`.

**Precedencia, de mayor a menor:**

1. `LCC_AUTH_ENGINE` — la escotilla de diagnóstico. Si está, gana. Sin esto, el QA en
   entorno hostil (que lanza con esa variable) dejaría de poder forzar el motor.
2. El fichero de ajustes.
3. El defecto: **nativo**.

**Se descartó un setter en memoria llamado por Dart al arrancar.** Tiene una carrera
real: cualquier llamada que llegue antes de que Dart lo fije usa el defecto en silencio,
y eso se manifiesta como "a veces arranca con el motor equivocado" — el tipo de fallo
que cuesta horas y que esta iniciativa ya ha pagado tres veces. Un fichero está
disponible desde la primera llamada, antes incluso de que exista la UI.

## Añadir y quitar cuentas bajo el motor gcloud

Los botones **siguen activos**. Abren un diálogo con el comando exacto, copiable, y un
botón de **actualizar** que relee la lista cuando el usuario vuelve de su terminal:

- Añadir → `gcloud auth login`
- Quitar → `gcloud auth revoke <cuenta>`

Deshabilitarlos era la alternativa, y se descartó: un botón gris es una mala forma de
enseñar. Este patrón ya existe en la app —los diálogos de diagnóstico muestran comandos
`gcloud …` para copiar—, así que no introduce un concepto nuevo.

Bajo el motor nativo, ambos botones siguen haciendo lo que hacen desde D4.

## El botón de login del dashboard

`lib/main.dart:504` llama hoy a `gcloudLogin()` → `execute_login`, que desaparece. Pasa a
ser consciente del motor: bajo nativo ejecuta el OAuth propio; bajo gcloud abre el mismo
diálogo de instrucción.

**Esto es la vía de entrada tras actualizar**, así que no puede quedarse a medias: un
usuario que actualice y se despierte en nativo con el almacén vacío llega exactamente
aquí. `reauthenticate()` ya despacha por motor desde el 2026-08-18 (commit `9ad273a`).

## El aviso de una sola vez

Al primer arranque tras el cambio de defecto, un aviso explica que LCC ahora inicia
sesión por su cuenta y que **las cuentas de gcloud siguen disponibles** eligiendo ese
motor en Ajustes.

El "ya lo he visto" es estado de UI y vive en `StorageService` (`SharedPreferences`),
no en `engine.json`: el fichero de Rust guarda la preferencia del motor, no lo que el
usuario ha leído. El aviso se muestra cuando ese flag no está puesto **y** no hay
elección explícita en `engine.json` — es decir, a quien llega al defecto nuevo sin
haberlo pedido. Quien ya eligió motor a mano no necesita que le expliquen el cambio.

Sin él, quien actualice ve desaparecer sus cuentas del diálogo sin explicación. El
problema no es que cambie el motor: es que cambie sin decirlo.

Se descartó la "migración pegajosa" (dejar en gcloud a quien ya tenga cuentas allí):
retrasaría el defecto nuevo indefinidamente en las máquinas donde LCC ya está instalado,
y añade estado oculto que luego cuesta razonar.

## Doctor

Conserva sus checks de gcloud. Bajo el motor **nativo** reportan `Skipped` con el
motivo ("no aplica: el motor de auth es nativo") en vez de `Fail`; bajo el motor
**gcloud** siguen siendo `Pass`/`Fail` como hoy. Un usuario en nativo no debe ver un rojo
por no tener gcloud, y un usuario en gcloud sí debe verlo.

`Skipped` ya existe como estado y D4 lo usó exactamente así, de modo que no hay concepto
nuevo que introducir.

## Pruebas

**Puras, sin red ni ficheros:**

- La precedencia del selector, en sus tres niveles: sin nada ⇒ nativo; solo fichero ⇒ el
  del fichero; env + fichero en conflicto ⇒ gana el env. Ese último es el que protege la
  escotilla de diagnóstico y el QA en entorno hostil.
- Que un valor desconocido en el fichero cae al defecto en vez de fallar el arranque.

**De árbol, y va en la revisión, no en el QA:** tras regenerar el bridge,
`grep -rn 'execute_login\|execute_logout\|gcloudLogin\|gcloudLogout' native/src lib/src`
debe dar **cero**, incluido el bridge generado — si los envoltorios de `api.rs`
desaparecen, la regeneración los quita también. Un resto ahí significa una llamada
huérfana o una regeneración que no se hizo.

**Lo que no se puede probar sin una VM ni sin usuarios:** el diálogo de instrucción, el
aviso de una sola vez y el comportamiento de Doctor en cada motor. Van al QA manual.

## Criterio de corte — dos mitades

Ambas son obligatorias. Es el criterio de salida de toda la iniciativa junto con SG-E.

**1. Motor nativo, con `gcloud` inalcanzable.** Sandbox de `bwrap` con
`$HOME/google-cloud-sdk`, el SDK del sistema y `~/.config/gcloud` enmascarados —
**no** `chmod`, que ya produjo dos falsos verdes. LCC hace login, gestiona cuentas,
lista y gestiona VMs, y abre túneles y reenvíos.

**2. Motor gcloud seleccionado**, con una sesión de CLI válida: listar, cambiar de
cuenta, tokens y túneles siguen funcionando. Y cuando esa sesión caduca, **el mensaje
dice que hay que ejecutar `gcloud auth login`**, no un error genérico — ese fallo exacto
se leyó como "no autentica" el 2026-08-19.

La segunda mitad es la que evita que la escotilla se pudra. Sin ella D5 entrega una
opción que parece soportada y no lo está.

## Fuera de alcance

- Retirar gcloud de Doctor, del packaging y de los docs (**SG-E**).
- El motor de túnel y el de reenvío SSH: ya son nativos por defecto (SG-B y SP-2) y sus
  selectores siguen siendo variables de entorno. Sacarlos a Ajustes junto al de auth es
  candidato para SG-E, no para aquí.
- Cualquier cambio en la gestión de cuentas nativa, que quedó cerrada en D4.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Un usuario actualiza y cree que perdió sus cuentas | El aviso de una sola vez, y el botón de login que sí funciona en nativo |
| El selector no llega a Rust a tiempo y arranca con el motor equivocado | Fichero leído bajo demanda, no un setter en memoria con carrera |
| Se borra de más y se mutila la escotilla | La tabla de arriba, con el criterio "invoca vs. lee"; y la segunda mitad del corte, que la ejercita |
| La escotilla se pudre por no ejercitarse | La segunda mitad del corte es obligatoria, y la decisión del 2026-08-21 ya obliga a correrla en cada release o a documentarla como best-effort |
