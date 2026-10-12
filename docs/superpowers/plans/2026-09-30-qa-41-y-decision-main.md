# QA de la build .41 y la decisión sobre `main`

**Build a probar:** `27H1~preview.20260930.41` — comprueba en Ajustes que dice exactamente eso antes de empezar. Si dice otra cosa, el QA no vale.

**Cómo usar esto:** marca las casillas conforme avances. Donde pone *lo que esperas* y *lo que sería una regresión*, la diferencia importa: si ves lo segundo, apunta qué viste y pásame los logs de `~/.local/share/lightweight_cloud_connector/logs/`.

**Una advertencia que vale para todo el documento:** el log rota en UTC y tú estás en UTC−3. Después de las 21:00 locales, lo de "hoy" está en el fichero del día siguiente.

---

## 1. Lo nuevo de la .41

### 1.1 Las dos filas del gestor en español ← **la más importante**

Es lo único de toda esta tanda que **ninguna máquina puede verificar**. Las medidas que tenemos (157–192 px de desbordamiento) salen de la fuente de `flutter test`, que es más ancha que la real. Puede que en pantalla nunca se notara nada — y saber cuál de las dos cosas es cierta también es un resultado.

- [ ] Idioma en **español**, y al menos **un túnel** en la lista del gestor
- [ ] Mira la **fila de abajo del diálogo**: *Desconectar todo*, *Limpiar zombis*, *Cerrar*
- [ ] Mira la **fila de acciones de cada tarjeta**, sobre todo en una **en error** (ahí salen a la vez el interruptor de reconexión, *Reintentar* y *Desconectar*)
- [ ] **Estrecha la ventana** hasta donde te resulte razonable usarla: es donde saltará si va justo

| | |
|---|---|
| Esperas | Los botones bajan de línea si no caben. Nada cortado, ninguna barra amarilla y negra |
| Regresión | Barra de desbordamiento, texto recortado, o un botón que se sale |

> Si **nunca** se ve mal ni estrechando, dilo: significaría que el problema solo existía con la fuente del test, y conviene que quede escrito.

### 1.2 Etiqueta de motor en cada entrada

- [ ] Abre un túnel. Su fila debe decir qué motor lo sostiene: **Nativo** o **gcloud**
- [ ] **Sin cerrarlo**, cambia el motor en Ajustes y abre un segundo túnel
- [ ] Comprueba que **cada fila conserva el suyo**

Esto último es el caso que de verdad importa: una entrada la sostiene el motor que había **cuando se creó**, no el que esté seleccionado ahora. Si las dos filas cambian a la vez, está leyendo el motor equivocado.

### 1.3 El motor en la fila en error

- [ ] Fuerza un fallo de arranque — por ejemplo un puerto remoto que el firewall de IAP no abra
- [ ] La fila roja debe decir **qué motor falló**
- [ ] Repítelo con el otro motor y comprueba que cambia

### 1.4 Los motores en el log de arranque

- [ ] Abre la app y avísame: yo leo el log y busco la línea

Debe aparecer algo así, justo después de `Logging system initialized`:

```
Engines in force at startup  engines="auth=native[default] tunnel=native[default] ssh_forward=native[default]"
```

Opcional, para probar el aviso de variable mal escrita:

- [ ] Lánzala desde terminal con `LCC_TUNNEL_ENGINE=gcluod` y avísame

La línea debería decir `set but not understood` en esa ranura — el valor en crudo **no** se registra, a propósito.

---

## 2. Lo que sigue sin probar de antes (SG-E)

Esto lleva pendiente desde agosto. No bloquea nada hoy, pero son los huecos que quedan.

- [ ] **Item 1 — Doctor en entorno hostil.** El Doctor bajo el motor nativo, dentro de un sandbox `bwrap` sin `gcloud` ni ADC. Lo que se comprueba es que las filas de gcloud salgan en *Skipped* y no en rojo. **Nunca con `chmod`**: esa vía ya nos dio dos falsos verdes.
- [ ] **Item 3 — Llavero caído.** Con el llavero del sistema parado, que la app lo diga en vez de fallar de forma opaca.
- [ ] **Item 4 — Sin ninguna cuenta.** Arranque limpio, sin cuentas configuradas.
- [ ] **Item 5 — Quedó a medias.** Repasar qué falta exactamente del criterio de corte.
- [ ] **Item 7 — Variable de entorno forzando el motor.** Con la `.41` esto es más fácil que antes: la línea de arranque ahora dice de dónde sale cada motor, así que la comprobación es leer el log en vez de deducirlo.

---

## 3. Lo que sigue roto o a medias, por si lo ves durante el QA

No hay que probarlo, pero si te cruzas con ello ya sabes que está identificado:

| | Estado |
|---|---|
| **VNC**: el puerto 5900 está fijo en el código | En curso — lo estoy diseñando |
| **Reenvío nativo en reposo**: no se entera de que murió hasta que alguien conecta | Encargado a lcc-91 |
| `is_port_listening` no comprueba que el listener sea nuestro | Decidido no hacerlo: es una carrera de milisegundos, documentado en el código |
| Sin error ruidoso ante un cambio de ABI del puente | Apuntado, valor bajo |
| La clave SSH que dejé en el metadata de `lcc-app-505403` | **Pendiente de que decidas** |
| 4 ficheros ajenos sin commitear (`analysis_options.yaml`, `native/Cargo.toml`, `security.yml`, `deny.toml`) | **Pendiente de que decidas** |

---

## 4. La decisión sobre `main`

### Dónde estamos, con números

```
27H1-Preview por delante de main:  377 commits
main por delante de 27H1-Preview:    0 commits
diferencia:  216 ficheros, +52.757 / −5.245 líneas
```

**Esto no es una fusión: es una release.** Son meses de trabajo — i18n completo, el motor nativo de IAP, el reenvío SSH nativo, el cutover de D5, SG-E, y todo lo de estas dos semanas.

### Qué significa publicarlo

`main` vive en el repositorio **público** (`jordilopezr/LCC`). Fusionar convierte en público el motor nativo entero y lo pone como comportamiento por defecto para cualquiera que lo instale.

### Mi recomendación: todavía no

No porque el código esté mal — está más probado que nunca —, sino porque **hay tres cosas que un usuario nuevo se encontraría de frente**:

1. **VNC solo funciona en el puerto 5900.** Está fijo en el código. Alguien con VNC en otro puerto se lo encuentra roto sin explicación.
2. **El QA de SG-E de la sección 2 sigue abierto.** Son justo los escenarios de un usuario que no es tú: sin `gcloud`, sin cuentas, con el llavero caído. Los que más importan en una release pública.
3. **Un reenvío nativo en reposo no se entera de que murió.** Está encargado, pero hoy es así.

Ninguna es catastrófica. Las tres son cosas que tú ya sabes esquivar y un desconocido no.

### Qué tendría que ser cierto para fusionar

- [ ] VNC funciona en un puerto que no sea el 5900
- [ ] Los items de la sección 2 pasados, en particular el 1 y el 4 (entorno hostil y sin cuentas)
- [ ] El QA de la sección 1 en verde
- [ ] Decidido qué hacer con los 4 ficheros ajenos sin commitear
- [ ] Decidido si la clave SSH sale del metadata del proyecto

### Y una pregunta que hay que contestar antes, no después

**¿Cómo entra en `main`?** El historial público se aplastó una vez (`main` se publicó con historial limpio en julio). Con 377 commits detrás, las opciones no son equivalentes:

- **Merge normal** — entra todo el historial, incluidos los mensajes en español y el rastro de nuestros ires y venires. Honesto y trazable.
- **Squash** — un único commit de release. Limpio de cara a fuera, pero se pierde el porqué de cada decisión, que en este proyecto está casi todo en los mensajes de commit.

No tengo una recomendación fuerte. Depende de si el repositorio público es un escaparate o un historial de ingeniería. Lo que sí diría: **decídelo antes de empezar**, porque cambiar de idea a mitad es caro.

---

*Escrito el 2026-09-30. Si algo de aquí ya no encaja con lo que ves, gana lo que ves.*
