# SG-E — Cierre: Doctor nativo, motores visibles y documentación honesta (spec de diseño)

**Fecha:** 2026-08-25
**Rama:** `27H1-Preview`
**Sub-proyecto:** SG-E, cierre de la iniciativa de salida de `gcloud`
**Depende de:** SG-A ✔, SG-B ✔, SG-C ✔, SG-D (D0–D5) ✔, SP-1 ✔, SP-2 ✔
**Roadmaps:** [SG-D](2026-08-12-sgd-oauth-roadmap.md) · [salida de gcloud](2026-08-12-gcloud-removal-roadmap.md)

## Dos correcciones al roadmap

El roadmap describe SG-E como "retirar gcloud de Doctor, del packaging y de los
docs". Al explorar el terreno, dos de esas tres piezas no son lo que dice:

**1. Los paquetes nunca declararon gcloud como dependencia.** `package_deb.sh:10`,
`package_rpm.sh:17` y `packaging/arch/PKGBUILD:9` listan gtk3, libsecret, remmina y
poco más. No hay nada que retirar del empaquetado. Lo que sí instala gcloud —siempre,
como paso obligatorio 4/9— es `scripts/setup_environment.sh`, que es el script de
entorno de desarrollo.

**2. Los remedios de auth de Doctor ya dependen del motor.** La ronda de arreglos de
D5 introdujo `token_failure_remedy` (`native/src/doctor.rs:120`) y dejó las tres filas
de gcloud en `Skipped` bajo el motor nativo. Los comandos `gcloud …` que quedan en
`doctor.rs` —`:396`, `:437`, `:451`, `:656`, `:770`, `:810`— **no son de
autenticación**: habilitan APIs, crean la regla de firewall de IAP, arrancan una VM.

Ese segundo punto reencuadra el sub-proyecto entero: **SG-E casi no borra. Añade.**

## El criterio que decide cada caso

D5 usó "¿esto **invoca** la auth de gcloud, o solo la **lee**?". El de SG-E:

> **¿Este texto le dice al usuario que se autentique con gcloud, o que administre GCP
> con gcloud?**

Lo primero depende del motor, y ya está resuelto. Lo segundo se queda: quien necesita
abrir el firewall de IAP lo hace con gcloud o con la consola, tenga el motor que tenga.

## La preferencia de motores, generalizada

Hoy hay tres selectores y un solo mecanismo. `LCC_AUTH_ENGINE` pasa por
`engine_pref.rs` con precedencia y fichero; `LCC_TUNNEL_ENGINE` y
`LCC_SSH_FORWARD_ENGINE` solo leen el entorno (`native/src/tunnel.rs:38` y `:56`).

`engine.json` pasa de una clave a tres — `auth_engine`, `tunnel_engine`,
`ssh_forward_engine` — y `engine_pref.rs` expone un `resolve(env, clave)` único con la
precedencia **entorno > fichero > nativo**. Añadir claves al fichero es compatible con
los que ya existen en las máquinas donde D5 ya corrió.

**Ninguno de los tres cachea.** `auth_engine()` relee el fichero en cada llamada a
propósito, y esa decisión ya se pagó: el hallazgo crítico de la revisión final de D5
fueron dos cachés —`TOKEN_CACHE` y `CACHED_AUTH_CLIENT`— construidas cuando el motor
era fijo por proceso. Los otros dos se leen una vez por túnel o por reenvío, así que el
coste de releer un JSON minúsculo no se nota.

**Se descartó** un módulo de preferencias genérico clave-valor: hay exactamente tres
claves y nadie más pide uno. Y se descartó un módulo por motor: tres copias de la misma
regla de precedencia son tres sitios donde arreglar el próximo fallo, y solo se
arreglará en uno.

## Ajustes: un bloque «Avanzado», plegado

Bajo el selector de método de inicio de sesión, un desplegable **cerrado por defecto**
con los motores de túnel y de reenvío SSH.

El de auth es una elección real del usuario: decide qué cuentas ve. Estos dos son
escotillas de diagnóstico —nadie sabe cuál quiere hasta que algo falla—, y el motor
nativo es estrictamente preferible en ambos. Plegarlos los deja localizables para
soporte ("Ajustes → Avanzado → cambia el motor de túnel y reinténtalo") sin invitar a
tocarlos. `native/src/tunnel.rs:37` decía "deliberately not exposed in Settings"; esto
lo revierte a medias y a propósito, y ese comentario se actualiza.

Reutiliza el aviso de anulación por entorno que D5 construyó: si la variable
correspondiente está puesta, el bloque lo dice y nombra el motor realmente en vigor.

**Cambiar el motor de túnel no afecta a los túneles ya abiertos**, solo a los
siguientes. Es lo correcto —cerrarle al usuario sus túneles por tocar un ajuste sería
peor— pero sorprende, así que la sección lo dice en una línea.

## Doctor: tres comprobaciones nativas

Simétricas a lo que D5 hizo con las filas de gcloud: bajo el motor **gcloud** salen en
`Skipped` con su motivo; bajo **nativo** son determinantes.

| Comprobación | Qué hace | Por qué |
|---|---|---|
| **Almacén de credenciales alcanzable** | Sondea el keyring con una entrada que no existe. `NoEntry` ⇒ responde; `NoStorageAccess`/`PlatformFailure` ⇒ roto | Es la prueba que le faltó a **D2**, que pasó el QA en verde compilando contra el *mock* del crate y sin persistir nada |
| **Índice y keyring coherentes** | Compara `oauth_accounts.json` con lo que el keyring tiene de verdad | Una cuenta listada sin token guardado se manifiesta como "aparece en la lista pero no autentica" |
| **El token se acuña ahora** | Refresca de verdad contra Google con el refresh token guardado | La única de punta a punta, y la única que hace red |

`token_store` ya distingue el fallo de backend del "no existe" y le da mensaje
accionable (`token_store.rs:163`), así que la primera comprobación reutiliza eso en vez
de inventar su propia clasificación.

**La tercera tiene que distinguir dos casos.** Sin una fila de "cuenta activa", alguien
recién instalado vería un error de token cuando lo que le pasa es que no ha entrado:

- **No hay ninguna cuenta** ⇒ mensaje "no ha iniciado sesión", acción de entrar.
- **Hay cuenta y el refresco falló** ⇒ fallo de refresco, acción de reautenticar.

## Los remedios de administración

Se conservan los comandos `gcloud …` de `:396`, `:437`, `:451`, `:656`, `:770` y
`:810`, y se **añade en `details` la ruta equivalente en la consola de Google Cloud**.
Ofrecerle a un usuario sin gcloud una única salida que pasa por gcloud es dejarlo sin
salida; y borrar el comando le quita la buena a quien sí lo tiene.

## Documentación

`README.md` y `README.es.md` a fondo: requisitos, instalación, autenticación, la
sección de Doctor y la de «Dual API». **gcloud deja de ser el requisito número 1 y pasa
a opcional**, con una frase que diga para qué sirve todavía —la escotilla de auth, y
los comandos de administración—. Hoy el README describe una aplicación distinta de la
que existe, y es lo primero que lee quien se encuentra el proyecto.

Después, pasada de coherencia por `SECURITY.md`, `THREAT_MODEL.md` y `SSOT.md`.

`scripts/setup_environment.sh` deja de instalar gcloud como paso obligatorio: pasa a
opcional y explicado. Si el README dice "opcional" y el script de entorno lo instala
siempre, se contradicen — y el script es lo que ejecuta quien clona el repo por primera
vez. `scripts/setup_macos.sh` queda fuera: el release de macOS está diferido.

## Pruebas

**Puras, sin red ni ficheros:**

- La precedencia generalizada, en sus tres niveles y para las tres claves: sin nada ⇒
  nativo; solo fichero ⇒ el del fichero; entorno + fichero en conflicto ⇒ gana el
  entorno.
- Que un `engine.json` escrito por D5 —con solo `auth_engine`— sigue leyéndose, y las
  otras dos claves caen al defecto. Es la compatibilidad hacia atrás, y falla en
  silencio si nadie la prueba.
- Que un valor desconocido en cualquier clave cae al defecto en vez de romper el
  arranque.
- La clasificación de las tres comprobaciones nativas por motor, con la misma forma de
  función pura que `gcloud_check_status`.
- Que la comprobación del token distingue "no hay cuenta" de "el refresco falló".

**La prueba negativa, obligatoria:** cada comprobación nativa nueva debe tener una
guarda que **falle** si se reintroduce el defecto que detecta. Un test que pasa con y
sin el fallo no es un test — y ésa fue la señal que faltó en D2, D3 y SG-B.

**Lo que no se puede probar sin una máquina ni sin usuarios:** el bloque plegado de
Ajustes, el efecto real de cambiar de motor de túnel, y Doctor con el keyring caído.
Van al QA manual.

## Criterio de corte

El del roadmap —"demostrar que lo que borra no lo llamaba nadie"— no aplica: SG-E casi
no borra. El suyo:

1. **Doctor pasa entero, sin ninguna fila roja, en el sandbox de `bwrap` sin gcloud y
   con el motor nativo**, y las tres comprobaciones nativas están en verde.
2. **Doctor sigue diagnosticando bien con el motor gcloud seleccionado**: las filas de
   gcloud vuelven a ser determinantes y las nativas pasan a `Skipped`.
3. **Los tres selectores surten efecto sin reiniciar**, verificado **por log**, no por
   la UI. Dos rutas que producen el mismo resultado en pantalla no se distinguen
   mirando la pantalla: ése fue el fallo de método que dio tres falsos verdes.
4. **El README no afirma nada que la aplicación no haga.**

## Fuera de alcance

- `scripts/setup_macos.sh` y todo lo de macOS: el release está diferido.
- Retirar el motor gcloud de cualquier sitio. La decisión del 2026-08-21 lo conserva.
- Los tests de Dart de la capa de consentimiento de SSH, y la reversión por UI de un
  rechazo de consentimiento: deuda anotada, ajena a este sub-proyecto.
- `log_out_all`, que aborta en el primer borrado que falla.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| La clave nueva rompe el `engine.json` que D5 ya escribió en máquinas reales | Un test de compatibilidad hacia atrás con el fichero de una sola clave |
| Un usuario cambia el motor de túnel "porque estaba ahí" y se rompe | El bloque va plegado, con advertencia, y el nativo es el defecto |
| La comprobación del token añade segundos a cada pasada de Doctor | Es una sola llamada de refresco, con el mismo timeout que las demás; y es la única que prueba la cadena entera |
| Doctor pasa en verde con el keyring roto, como en D2 | La comprobación del almacén existe precisamente para eso, y su guarda negativa es obligatoria |
