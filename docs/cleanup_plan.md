# Plan de Trabajo: Eliminación del Modelo de Licencias (LCC 100% Gratis)

> **Estado: COMPLETADO (2026-07).** El modelo de licencias fue eliminado por completo: no existen `native/src/license.rs`, `lib/src/features/license_provider.dart` ni `lib/src/widgets/pro_gate.dart`, y el fichero generado `lib/src/bridge/api.dart/license.dart` fue borrado. Este documento se conserva como registro histórico del plan.

Este documento detalla los pasos necesarios para eliminar completamente la separación de versiones (Free vs Pro) en Lightweight Cloud Connector (LCC), unificando todas las funcionalidades en una única versión gratuita y eliminando cualquier mecanismo de validación de licencias.

## 1. Limpieza en el Backend (Rust - `native/`)

El modelo actual utiliza validación de firmas Ed25519 en Rust para verificar el archivo `license.key`. Todo esto debe ser eliminado.

- **Eliminar `native/src/license.rs`:** Borrar el archivo completamente, ya que contiene la lógica de validación criptográfica, las claves públicas (`PUBLIC_KEYS`), y la lectura del archivo.
- **Actualizar `native/src/api.rs` y `native/src/lib.rs`:** Eliminar las exportaciones y referencias al módulo `license` (ej. `verify_license_file`, `get_license_file_path`, structs como `LicenseInfo`, `LicenseTier`).
- **Limpiar dependencias:** Si `ed25519-dalek` o módulos similares en `Cargo.toml` solo se usaban para las licencias, removerlos.
- **Limpiar `native/src/diagnostics.rs`:** Remover cualquier texto o lógica condicional relacionada con "Premium" o "Pro".

## 2. Limpieza en el Frontend (Dart/Flutter - `lib/`)

Se deben eliminar los Providers y Widgets creados específicamente para bloquear funcionalidades a los usuarios del nivel gratuito.

- **Eliminar `lib/src/features/license_provider.dart`:** Borrar el provider que maneja el estado de la licencia (`LicenseNotifier`, `isProProvider`) y la integración con el bridge de Rust.
- **Eliminar `lib/src/widgets/pro_gate.dart`:** Borrar el widget que intercepta el acceso a funcionalidades Pro (`ProGate`), así como los diálogos de activación (`showLicenseActivationDialog`, `_LicenseActivationDialog`).
- **Limpiar el Bridge generado:** Eliminar `lib/src/bridge/api.dart/license.dart` (o regenerar el código con `flutter_rust_bridge_codegen` una vez que Rust esté limpio).

## 3. Desbloqueo de la Interfaz de Usuario (UI)

Hay que buscar todas las referencias a `isProProvider` y `ProGate` en la aplicación y eliminarlas, dejando el contenido subyacente siempre accesible.

### 3.1. `lib/src/features/settings_dialog.dart`
- Eliminar la inyección de `isProProvider` (`final isPro = ref.watch(isProProvider);`).
- **Auto-Refresh:** Eliminar el condicional que bloqueaba el intervalo personalizado (`if (!isPro) ... _ProLockedTile`). Permitir que cualquier usuario seleccione intervalos y opciones personalizadas.
- **Clientes RDP y VNC:** Eliminar el uso de `_ProLockedSection` y `_ProBadge`. Permitir la libre selección de los clientes RDP y VNC (Remmina, TigerVNC, etc.).
- Eliminar los componentes internos sobrantes: `_ProLockedTile`, `_ProLockedSection`, `_ProBadge`.

### 3.2. Referencias Adicionales (`main.dart`, `gcloud_provider.dart`, etc.)
- Buscar y eliminar cualquier uso restante de `isProProvider` en todo el proyecto.
- Remover imports a `pro_gate.dart` y `license_provider.dart`.
- Si existen botones en el layout principal (ej. un botón "Activar Pro" o una insignia "Free Tier"), eliminarlos.

## 4. Limpieza de Textos, Copys y Documentación

Todas las referencias al modelo de negocio anterior deben desaparecer para evitar confusiones.

- **Textos en la UI:** Buscar en el código (con `grep` o en el IDE) palabras como `"Pro"`, `"Premium"`, `"Free"`, `"licencia"`, y `"tier"`. Eliminar mensajes promocionales, prompts de actualización y descripciones de pago.
- **`README.md`:** Actualizar la documentación principal. Eliminar tablas de precios, comparativas entre versiones, instrucciones de cómo cargar el archivo `.key`, y añadir un bloque destacando que LCC ahora es completamente gratuito y open-source con todas las funcionalidades desbloqueadas.
- **Licencia del Repositorio (`LICENSE`):** Asegurarse de que el archivo de licencia del repositorio sea adecuado para un proyecto 100% libre (ej. MIT, Apache 2.0 o GPL), reemplazando cualquier licencia comercial propietaria si existiese.

## Siguientes Pasos

Para ejecutar esta limpieza de forma segura, se recomienda:
1. Crear una nueva rama `feature/remove-license-model`.
2. Ejecutar la eliminación del código de Rust y regenerar el bridge de Flutter-Rust.
3. Proceder con la limpieza en la capa de Dart (providers y widgets).
4. Probar exhaustivamente que la aplicación compila y que funcionalidades avanzadas (como VNC y selección de intervalo de refresco) funcionan sin requerir activación.
