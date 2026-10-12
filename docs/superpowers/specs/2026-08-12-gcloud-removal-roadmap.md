# Roadmap: eliminar la dependencia de `gcloud` (iniciativa multi-sub-proyecto)

**Fecha:** 2026-08-12
**Rama:** `27H1-Preview`
**Estado:** Roadmap para decidir secuencia (no es un spec de diseño de un sub-proyecto)
**Tipo:** Documento de secuencia/descomposición. Cada sub-proyecto tendrá su propio brainstorm → spec → plan.

## Objetivo final (criterio de salida global)

> **Revisado el 2026-08-21 tras las pruebas con usuarios.** El objetivo ya no es
> erradicar gcloud, sino **dejar de necesitarlo**. Ver "El motor gcloud se
> conserva" más abajo: los usuarios están conformes con el motor nativo y piden
> que la ruta gcloud siga existiendo, porque en algunos casos hace falta.

LCC funciona **sin necesitar el CLI `gcloud`**: auth, datos, lifecycle y túnel IAP tienen
ruta nativa, y esa ruta es la de por defecto. Prueba de aceptación: en una máquina donde
`gcloud` no es alcanzable, LCC puede autenticarse, listar/cambiar cuentas,
listar/gestionar/conectar instancias y abrir túneles IAP — todo en verde.

**Lo que NO es el objetivo:** borrar el motor gcloud del código. Se conserva como
escotilla seleccionable.

## El motor gcloud se conserva (decisión del 2026-08-21)

Las pruebas con usuarios dieron dos resultados: contentos con el motor nativo, y una
petición explícita de **no eliminar el de gcloud** — nativo por defecto, gcloud
disponible porque en algunos casos es necesario (setups de auth atípicos —federación de
identidad, suplantación de cuenta de servicio, proxies configurados en gcloud—, o una
organización que bloquee el cliente OAuth de LCC).

La escotilla ya se ganó su sitio durante el desarrollo: cuando el túnel nativo llevaba
cuatro builds roto sin que nadie lo supiera, `LCC_TUNNEL_ENGINE=gcloud` fue lo que
permitió seguir trabajando y acotar el fallo. Un motor alternativo no sirve solo al
usuario: es instrumento de diagnóstico.

**Se adopta la opción B: gcloud como escotilla mantenida por el usuario.** LCC la usa si
está autenticada, pero **nunca invoca su auth**. Si la sesión del CLI caduca, el usuario
ejecuta `gcloud auth login` en su terminal. La alternativa —que LCC siguiera refrescando
la sesión de gcloud— obligaría a conservar `execute_login` y dejaría la iniciativa a
medias por diseño.

Esto no es gratis, y las dos condiciones siguientes son parte de la decisión:

1. **La escotilla tiene que ser encontrable.** Hoy son variables de entorno
   deliberadamente no expuestas (`LCC_AUTH_ENGINE`, `LCC_TUNNEL_ENGINE`,
   `LCC_SSH_FORWARD_ENGINE`). Una escotilla que solo conoce quien leyó el código no
   existe: pasa a ser una opción visible en Ajustes, con un texto que diga qué implica
   elegirla — incluido que su sesión la mantiene el usuario.
2. **Y tiene que ejercitarse, o se pudre.** Esta iniciativa demostró tres veces que un
   camino fuera del defecto y sin pruebas deja de ser una capacidad y pasa a ser una
   afirmación: el túnel nativo "funcionando" cuatro builds, el keyring compilando al
   mock del crate, la ruta nativa de D3 inalcanzable sin el fichero ADC. Si el motor
   gcloud se conserva, su QA se corre en cada release, aunque sea una matriz corta. Si
   no se va a correr, lo honesto es documentarlo como *best-effort, sin garantías* — no
   dejar que parezca soportado.

## Superficie actual de `gcloud` (invocaciones funcionales)

- **Auth:** `auth login`, `auth application-default login`, `auth print-access-token`, `auth list`, `config get/set account`, `auth revoke` — en `native/src/gcloud.rs` + la ruta de token de `native/src/gcp_rest_client.rs`.
- **Datos:** `get_projects`, `get_instances`, `get_instance` (gcloud es *fallback*; REST es primario).
- **Lifecycle:** `start/stop/reset_instance` en `gcloud.rs` (el Dart `*WithMethod` alterna REST↔gcloud).
- **Túnel:** `compute start-iap-tunnel` (`Backend::Gcloud`, default actual).
- **Doctor:** comprueba gcloud instalado/autenticado (`native/src/doctor.rs`).
- **Solo texto (no invocación):** diálogos de diagnóstico/snapshots muestran comandos `gcloud …` para copiar — no ejecutan gcloud.

## Dos hechos que reducen el tamaño

1. **El lifecycle por REST ya existe:** `gcp_rest_client.rs` tiene `list_instances`/`get_instance` + `start/stop/reset/suspend/resume_instance` contra `compute.googleapis.com/compute/v1` (líneas ~919-1072). Quitar gcloud de datos/lifecycle = borrar la rama gcloud, no escribir REST nuevo.
2. **El refresco OAuth ya es nativo:** `token_from_adc_refresh` (líneas ~208-242) hace `grant_type=refresh_token` contra `oauth2.googleapis.com/token` con `reqwest`. Lo único nuevo/difícil en identidad es el **login inicial** (authorization-code) que hoy produce `gcloud auth login`, más el `print-access-token` que preferimos por RAPT.

**Conclusión:** el único trabajo net-new de alto riesgo es **SG-D** (login OAuth propio + almacén de token). El resto es borrar ramas y cambiar defaults.

## Los 5 sub-proyectos

### SG-A — REST por defecto para datos + lifecycle · Riesgo BAJO
- **Qué:** quitar la rama gcloud del toggle `*WithMethod` y del fallback de `manual_instance_dialog`; REST como única ruta para proyectos/instancias/lifecycle; borrar las fns de datos/lifecycle muertas de `gcloud.rs`.
- **Decisión abierta:** ¿se conserva un fallback gcloud de emergencia? (El fallback existe porque el token REST a veces fallaba; si lo quitamos, SG-C/D deben ser robustos.)
- **Criterio de corte:** ningún path llama a gcloud para datos/lifecycle de compute; todos los botones de lifecycle funcionan por REST; tests verdes.
- **Nota:** aún depende de gcloud para el **token** → no elimina gcloud todavía.

### SG-B — Túnel IAP nativo por defecto · Riesgo MEDIO
- **Qué:** `Backend::Native` como default; retirar `Backend::Gcloud` (`start-iap-tunnel`).
- **Decisión abierta:** ¿retirar gcloud del túnel ya, o dejarlo una release como fallback opt-out por env?
- **Criterio de corte:** túneles (directo + SSH forward) funcionan con nativo por defecto en toda la matriz de QA; `start-iap-tunnel` no se invoca por defecto.
- **Riesgo:** robustez del túnel nativo como default (ha sido opt-in).

### SG-C — Adquisición de token nativa · Riesgo BAJO-MEDIO
- **Qué:** dejar de preferir `gcloud auth print-access-token`; usar siempre el refresco ADC nativo; portar el manejo de RAPT/reauth de Workspace a la ruta nativa (hoy RAPT es el motivo de preferir print-access-token).
- **Criterio de corte:** tokens de acceso obtenidos nativamente para todas las llamadas REST, incluido tras reauth RAPT; no se llama a `print-access-token`.
- **Nota:** aún lee el fichero ADC (creado por gcloud) → no es eliminación total.

### SG-D — Login OAuth propio + almacén de token · Riesgo ALTO (poste largo)
- **Qué:** cliente OAuth propio de LCC (tipo *installed/desktop app*); flujo authorization-code con redirección loopback en navegador para obtener el `refresh_token`; guardado seguro (libsecret); reimplementar multi-cuenta (list/switch/add/remove) sobre ese almacén. Reemplaza `gcloud auth login` y `application-default login`.
- **Criterio de corte:** una máquina sin gcloud puede hacer login, listar/cambiar/añadir/quitar cuentas, y todo REST + túnel funciona. **Aquí gcloud deja de ser necesario.**
- **Decisiones abiertas clave:** qué cliente OAuth (registrar uno propio en un proyecto GCP; los clientes *desktop* no guardan secreto de verdad — el modelo installed-app de Google lo asume); redirección loopback (`127.0.0.1:puerto`) vs copia manual; scopes (`cloud-platform`); almacén libsecret; UX de reauth RAPT/Workspace; modelo multi-cuenta y cuál es la "activa".

### SG-E — Limpieza Doctor + packaging + docs · Riesgo BAJO (cierre)
- **Qué:** Doctor **añade** checks de auth nativa y **conserva** los de gcloud, degradados a informativos salvo cuando el motor gcloud está seleccionado, donde siguen siendo determinantes; retirar gcloud de las dependencias **requeridas** de packaging y documentarlo como **opcional**; los hints `gcloud …` de los diálogos se quedan, porque con la escotilla viva siguen siendo accionables.
- **Criterio de corte:** Doctor pasa sin gcloud con el motor nativo, y sigue diagnosticando correctamente con el motor gcloud seleccionado; docs/packaging listan gcloud como opcional, no como requerido.
- **Revisado el 2026-08-21:** este sub-proyecto ya no *retira* gcloud de Doctor. Ver "El motor gcloud se conserva".

## Estándar de verificación (obligatorio para D4, D5 y SG-E)

Tres sub-proyectos de esta iniciativa pasaron su QA en verde **sin funcionar**:

| | El QA dijo | La realidad |
|---|---|---|
| **D2** | "el keyring funciona" | Compilaba al *mock* del crate: no persistía nada — y el mismo defecto afectaba a código ya publicado |
| **D3** | checklist completo en verde | El camino nativo era **inalcanzable** sin el fichero ADC que produce gcloud |
| **SG-B** | "lo probé, funciona" | El túnel nativo **nunca** llegó a establecerse (pánico de rustls + falta la cabecera `Origin`) |

Los tres comparten forma, y los tres se descubrieron en producción, no en revisión. De ahí estas cuatro reglas, que vinculan a todo lo que queda:

1. **Cada ítem de QA declara su evidencia, no una impresión.** No "SSH funciona", sino "el log dice `engine="native"` con ese puerto". Si un ítem no nombra la línea de log, el fichero o la salida exacta que lo demuestra, no está verificado.
2. **La prueba negativa.** Por cada afirmación: *¿qué test falla si esta funcionalidad no existe?* En los tres casos la respuesta era "ninguno" — y eso, por sí solo, era la señal. Un sub-proyecto sin al menos una guarda que falle en ausencia de la funcionalidad no está terminado.
3. **Verificar en el entorno hostil.** La máquina de desarrollo escondió los tres fallos porque tenía justo lo que los tapaba: el fichero ADC, un Secret Service vivo, gcloud instalado. Toda afirmación de independencia se prueba **retirando** eso (renombrar el ADC, sesión sin keyring, `PATH` sin gcloud).
4. **Desambiguar el camino.** Cuando dos rutas producen el mismo resultado en pantalla —túnel nativo vs SSH forward de gcloud, REST vs CLI—, la UI **no** sirve como evidencia. En esta sesión tres de cinco pruebas dadas por buenas iban por la ruta equivocada.

Aplicación concreta a lo que queda: **D4** debe demostrar la gestión de cuentas contra el almacén nativo (no contra `listGcloudAccounts`) y con la UI mostrando esa misma identidad; **D5** debe ejecutar su matriz completa con `gcloud` fuera del `PATH`, que es su único criterio de corte real; **SG-E** debe demostrar que lo que borra no lo llamaba nadie (grep + suite verde), no solo que compila.

## Secuencia recomendada

```
SG-A ─┐
      ├─(ganancias independientes, bajo riesgo, encogen superficie)
SG-B ─┘
        └─► SG-C ─► SG-D ─► SG-E
             (prep tokens) (poste largo: aquí se puede quitar gcloud) (cierre)
```

- **SG-A y SG-B** primero: valor inmediato y retiran gran parte del uso de gcloud sin tocar el flujo de auth arriesgado. Independientes entre sí.
- **SG-C** como refactor previo que deja limpio el punto de integración de SG-D.
- **SG-D** es el make-or-break: hasta que auth sea nativo, gcloud no se puede quitar.
- **SG-E** solo puede cerrar cuando SG-A..D han aterrizado.

**Alternativa:** diseñar **SG-D primero** (aunque se implemente después) para que sus restricciones (cliente OAuth, RAPT, almacén) se conozcan antes de secuenciar el resto.

## Encaje con el corte de 27H1

Toda la iniciativa es candidata a ser su **propia edición** ("sin gcloud") **después** del corte de 27H1, no un ítem pre-corte — salvo que se decida que SG-A/SG-B (bajo riesgo) entren en 27H1 y el resto quede para la siguiente. Decisión pendiente.

## Siguiente paso

Elegir el primer sub-proyecto a **diseñar** (brainstorm → spec → plan). Recomendación: **SG-A** (arranque de bajo riesgo con valor real) o **SG-D** (destapar antes las restricciones del poste largo).
