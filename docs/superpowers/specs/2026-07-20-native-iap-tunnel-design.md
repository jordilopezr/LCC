# Diseño: Túnel IAP nativo en Rust — 27H1

**Fecha:** 2026-07-20
**Rama:** `27H1`
**Estado:** Aprobado

## Objetivo

Implementar el protocolo de IAP TCP forwarding directamente en Rust, eliminando la dependencia de `gcloud compute start-iap-tunnel` (un proceso hijo por túnel) para crear túneles. Se aprovecha para estrenar el patrón de **errores tipados con código estable**, que resuelve el pendiente de i18n en la capa Rust.

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Alcance | Solo el túnel. Los access tokens siguen viniendo de `gcloud auth print-access-token` |
| Migración | Motor nativo por defecto, con **fallback automático a gcloud** si falla el establecimiento |
| Errores i18n | Sí, pero **solo en el módulo de túneles**; el resto de módulos migra después siguiendo el patrón |
| Validación | Tests unitarios del framing y la máquina de estados + verificación manual end-to-end contra GCP real |
| Estructura | Separada en capas: protocolo / sesión / listener |

## Protocolo de referencia

El protocolo no está documentado públicamente, pero la implementación de Google es legible en el SDK instalado localmente:
`/usr/lib/google-cloud-sdk/lib/googlecloudsdk/api_lib/compute/iap_tunnel_websocket_utils.py`

Constantes confirmadas ahí:

| Constante | Valor |
|---|---|
| URL | `wss://tunnel.cloudproxy.app/v4/connect` (y `/v4/reconnect`) |
| Host mTLS | `mtls.tunnel.cloudproxy.app` (fuera de alcance en 27H1) |
| Subprotocolo | `relay.tunnel.cloudproxy.app` |
| Tag length | 2 bytes; cabecera = tag + 4 bytes de longitud |
| Máx. trama de datos | 16384 bytes |
| `CONNECT_SUCCESS_SID` | `0x0001` |
| `RECONNECT_SUCCESS_ACK` | `0x0002` |
| `DATA` | `0x0004` |
| `ACK` | `0x0007` |

Codificación (big-endian): `DATA` = `>H I <bytes>` (tag, longitud, datos). `ACK` = `>H Q` (tag, bytes acumulados recibidos).

Query params de conexión: `project`, `zone`, `instance`, `interface=nic0`, `port`, `newWebsocket=True`.
Query params de reconexión: `sid`, `ack`, `newWebsocket`, `zone`.

> **Riesgo asumido:** al no ser un contrato público, Google puede cambiarlo sin aviso. El fallback a gcloud es la mitigación: si el protocolo cambia, los túneles siguen funcionando por la ruta antigua mientras se actualiza el módulo nativo.

## 1. Arquitectura

Módulo nuevo `native/src/iap_tunnel/`, en capas de pura a sucia:

- **`frame.rs`** — codificación/decodificación del subprotocolo. Funciones puras sobre `&[u8]`, sin red ni async. Contiene los tags, el límite de 16 KB y el parseo big-endian. Concentra los tests unitarios.
- **`session.rs`** — una sesión WebSocket contra el relay: construcción de URL, autenticación por cabecera `Authorization: Bearer`, contador de bytes recibidos para los ACKs, custodia del `sid` y lógica de reconexión.
- **`listener.rs`** — `TcpListener` en `127.0.0.1:<puerto>`; por cada conexión entrante levanta una sesión y hace de puente bidireccional.
- **`mod.rs`** — API pública del módulo, consumida por `tunnel.rs`.

`native/src/tunnel.rs` se mantiene como **fachada**: conserva `start_tunnel`, `stop_tunnel`, `check_tunnel_health`, `measure_tunnel_latency`, `cleanup_dead_tunnels`, `get_all_tunnels_status` y el registro global `TUNNELS`, pero internamente elige motor.

**Impacto en el bridge:** los *nombres y parámetros* de las funciones no cambian, pero el tipo de error sí (ver §3), así que **hay que regenerar el bridge** con el comando habitual:

```bash
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
```

Tras regenerar, revisar los call sites en `gcloud_provider.dart` y `tunnel_manager_dialog.dart`, ya que la regeneración ha roto llamadas en el pasado. Los widgets solo cambian donde hoy muestran el string de error crudo.

Dependencias nuevas en `native/Cargo.toml`: `tokio-tungstenite` y `futures-util`; añadir la feature `net` a `tokio`.

## 2. Flujo de datos

1. `start_tunnel()` reserva un puerto local libre y arranca el motor nativo.
2. `listener.rs` escucha en `127.0.0.1:<puerto>` y devuelve el puerto de inmediato. Desaparecen el `sleep(1000ms)` y el sondeo de hasta 10 s del código actual, porque ya no hay que adivinar cuándo está listo un proceso externo.
3. Al conectarse un cliente (SSH, RDP, SFTP), se abre el WebSocket al endpoint de conexión con el token en la cabecera.
4. El relay responde `CONNECT_SUCCESS_SID`; se guarda el `sid`.
5. Bytes del socket local → tramas `DATA` (troceando a 16 KB). Tramas `DATA` recibidas → socket local.
6. Se envía `ACK` con el total acumulado de bytes recibidos **cada vez que el acumulado desde el último ACK supera 2× el tamaño máximo de trama (32 KB)**, replicando el comportamiento del cliente de gcloud. Ese contador es lo que permite reanudar sin pérdida tras una reconexión.
7. Si el WebSocket cae, se reconecta a `/v4/reconnect` con `sid` y `ack`. Si la reconexión falla de forma reiterada, el túnel se marca no sano y el auto-reconnect existente actúa como hasta ahora.

## 3. Errores tipados

El módulo devuelve un enum en vez de strings:

```rust
pub enum TunnelError {
    NotAuthenticated,
    PermissionDenied,
    InstanceNotFound { instance: String },
    InstanceNotRunning,
    FirewallBlocked,
    RelayUnreachable,
    ProtocolError { detail: String },
    LocalPortUnavailable { port: u16 },
}
```

Cruza el bridge con un **código estable** en `snake_case` (`"permission_denied"`, `"instance_not_found"`…) más sus datos asociados. Dart lo mapea a claves `tunnelError*` en `app_en.arb` / `app_es.arb`, siguiendo las convenciones de i18n ya establecidas (paridad de claves, prefijo de módulo, registro neutro en español).

El campo `detail` de `ProtocolError` **no se traduce**: es información diagnóstica destinada a logs y reportes.

Este es el patrón que después seguirán `doctor.rs`, `sftp.rs`, `snapshots.rs` y `gcloud.rs`; migrarlos queda **fuera de alcance** de 27H1.

## 4. Fallback y selección de motor

- Por defecto se intenta el motor nativo.
- Si falla al establecer la primera sesión, `tunnel.rs` reintenta con gcloud y registra el motivo en el log estructurado. El túnel resultante es indistinguible para la UI.
- Variable de entorno `LCC_TUNNEL_ENGINE` con valores `native` (forzar nativo, sin fallback), `gcloud` (forzar el método antiguo) y ausente (comportamiento por defecto). Es una herramienta de depuración: **no se expone en Settings**.
- El fallback se retirará en una versión posterior, cuando el motor nativo acumule rodaje.

## 5. Pruebas

**Unitarias (Rust, sin red):**
- `frame.rs`: round-trip de cada tipo de trama; troceado en el límite de 16 KB; entradas truncadas a mitad de cabecera; tags desconocidos; longitudes que exceden el buffer.
- Lógica de ACK y reconexión con un transporte simulado (trait de transporte con implementación de prueba), verificando que el contador de bytes es correcto y que tras reconectar se reanuda desde el `ack` esperado.

**Manual end-to-end** (la hace el desarrollador contra una instancia real): SSH, RDP y SFTP sobre el túnel nativo, más una transferencia de fichero grande (`scp`) para ejercitar troceado y ACKs, y una prueba de reconexión cortando la red brevemente.

## Fuera de alcance en 27H1

- OAuth propio: los tokens siguen viniendo de `gcloud auth print-access-token`.
- Soporte mTLS / `mtls.tunnel.cloudproxy.app` y universos no predeterminados.
- Túneles por host/`dest_group` o Cloud Run: solo instancias por `zone`+`instance`+`interface`.
- Migrar el resto de módulos Rust a errores tipados.
- Retirar el fallback a gcloud.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| El protocolo no es un contrato público y puede cambiar | Fallback automático a gcloud; el módulo queda aislado tras la fachada |
| Código de red nuevo con framing binario | Capa `frame.rs` pura con cobertura unitaria alta; validación manual end-to-end antes de mergear |
| Proxies corporativos / TLS intercepting | Es precisamente uno de los escenarios donde el fallback salva la sesión; `RelayUnreachable` lo hace diagnosticable |
| Regresión silenciosa frente al motor actual | `LCC_TUNNEL_ENGINE` permite comparar ambos motores en la misma máquina |
