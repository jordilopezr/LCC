# QA manual — SP-2: el reenvío SSH nativo pasa a ser el defecto

**Build:** (rellenar con el `kBuild` probado)
**Requisito:** lanzar con `LCC_AUTH_ENGINE=native` y **sin** `LCC_SSH_FORWARD_ENGINE`.

Los tests unitarios cubren el trasiego de bytes del reactor (escritura parcial,
backpressure, half-close) con dobles en memoria. Lo que **no** pueden cubrir es el
transporte IAP, el handshake ssh2 y la limpieza en retorno temprano. Eso es lo que
prueban estos ítems.

## 1. El reenvío corre por el motor nativo

- [ ] Un reenvío SSH al **8443** se establece.

**Evidencia:** la línea del log

```
SSH forward established instance="…" remote_port=8443 local_port=… engine="native"
```

**`engine="native"` es el ítem entero.** Sin ese campo los dos motores son
indistinguibles —en el log y en la UI—, y esa ambigüedad ya mandó dos
diagnósticos por el camino equivocado en esta iniciativa. Si dice `"gcloud"`,
el cambio de defecto no está activo y el resto de ítems no prueban nada.

- [ ] Lo mismo al **3000**.

## 2. Los bytes llegan enteros

El reactor escribe en endpoints no bloqueantes, así que una escritura puede
aceptar solo parte del buffer. Si la cola se pierde, la corrupción es silenciosa
y proporcional al tamaño: invisible en una página pequeña, fatal en una descarga.

- [ ] A través del reenvío, transfiere un fichero de **al menos 50 MB** y
      compara su checksum con el del origen.

```bash
# en la VM
sha256sum /ruta/al/fichero
# en local, a través del puerto reenviado
sha256sum ~/descargado
```

**Evidencia:** los dos checksums, iguales. Un fichero pequeño **no** vale para
este ítem: cabe en una sola escritura y no ejercita la ruta que importa.

## 3. El servidor puede cerrar para delimitar la respuesta

Hay protocolos donde el fin del mensaje *es* el cierre del servidor. Si el
reenvío no propaga ese FIN, el cliente espera para siempre.

- [ ] Una petición HTTP con `Connection: close` a través del reenvío **termina**
      en vez de quedarse colgada.

```bash
curl -sS -H 'Connection: close' http://localhost:<PUERTO>/ -o /dev/null -w '%{http_code}\n'
```

**Evidencia:** `curl` devuelve el control con un código. Si se queda colgado, el
FIN no se propagó.

## 4. La escotilla sigue viva

La decisión del 2026-08-21 conserva el motor gcloud. Relanza con
`LCC_SSH_FORWARD_ENGINE=gcloud` y una sesión de CLI válida:

- [ ] El reenvío al 8443 se establece.

**Evidencia:** la misma línea del log, ahora con `engine="gcloud"`.

**Este ítem no es opcional.** Un camino fuera del defecto y sin ejercitar deja de
ser una capacidad y pasa a ser una afirmación — le pasó al túnel nativo durante
cuatro builds, al keyring de D2 y a la ruta nativa de D3. Si la escotilla no se
prueba en cada release, hay que documentarla como *best-effort*.

## 5. No quedan puertos ni procesos colgando

Tras cerrar los reenvíos de los ítems anteriores:

```bash
ss -lptn | grep -E 'ssh|lightweight' || echo "(ningún puerto retenido)"
```

- [ ] Sin puertos retenidos.

**Por qué importa:** el `start` nativo comenta que un retorno temprano sin
`iap.stop()` desprende su tarea de fondo y fuga el puerto del relay durante toda
la vida del proceso, y que el reaper de inactividad no puede ayudar porque ese
transporte nunca se registró en `TUNNELS`. Ese camino no tiene test.
