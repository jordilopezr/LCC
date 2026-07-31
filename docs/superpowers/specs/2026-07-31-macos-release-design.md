# Diseño: Release macOS de LCC (diferido — gated por cuenta Apple Developer)

**Fecha:** 2026-07-31
**Estado:** Anotado / diferido. NO iniciar implementación hasta resolver los gates administrativos (ver §Bloqueantes).
**Contexto:** El release **Linux** (deb/rpm/AppImage/tarball firmado + SBOM) ya está cerrado y verificado (`LCC 26H2u1`, build 20260730.1). Este documento captura qué haría falta para un release **macOS** usable, para retomarlo cuando el usuario tenga cuenta Apple Developer.

## Objetivo

Publicar un `.app`/`.dmg` de LCC para macOS que **instale y arranque en Macs ajenos** (sin bloqueo de Gatekeeper) y con las funciones núcleo operativas (SSH/SFTP, IAP, `gcloud`, clientes RDP/VNC).

## Estado actual del repo (verificado 2026-07-31)

- `scripts/build_macos.sh`: compila un **Universal Binary** (arm64 + x86_64), cross-compilando el Rust nativo para `aarch64-apple-darwin` y `x86_64-apple-darwin`. **No firma, no notariza, no genera `.dmg`.**
- `macos/Runner/*.entitlements`:
  - `Release.entitlements`: **solo** `com.apple.security.app-sandbox = true`. **Falta `network.client`** (¡y LCC necesita red saliente!).
  - `DebugProfile.entitlements`: sandbox + `allow-jit` + `network.server`.
- `project.pbxproj`: **`CODE_SIGN_IDENTITY = "-"`** (firma ad-hoc, NO Developer ID); **sin `DEVELOPMENT_TEAM`**.
- Bundle ID aún es el de plantilla: **`com.example.linuxCloudConnector`** (hay que cambiarlo a un dominio inverso real).

## Bloqueantes (gates — resolver ANTES de implementar)

1. **Cuenta Apple Developer** ($99/año) → certificado **Developer ID Application**. Sin esto, la distribución fuera de la App Store queda bloqueada por Gatekeeper (la attestation keyless de Sigstore **no** sustituye la notarización de Apple). **Este es el gate principal.**
2. **Decisión sobre el sandbox.** Con `app-sandbox` activado y entitlements mínimos, LCC estaría **funcionalmente roto**: el sandbox bloquea red saliente (falta `network.client`), lanzar `gcloud` y clientes externos (RDP/VNC/ssh), y leer `~/.config/gcloud` y `~/.ssh`. Opciones:
   - (a) Reescribir entitlements para habilitar lo necesario dentro del sandbox (complejo; algunas cosas —lanzar binarios arbitrarios como `gcloud`— son difíciles/imposibles bajo sandbox), o
   - (b) **Quitar el sandbox** (más realista para esta app) → entonces **obligatorio** Developer ID + notarización + *hardened runtime*, y queda fuera de la Mac App Store.

## Requisitos de implementación (cuando se levanten los gates)

1. **Bundle ID real** + `DEVELOPMENT_TEAM` en el proyecto Xcode.
2. **Firma**: `codesign` con Developer ID Application sobre el `.app` **y todas las dylibs embebidas** (incluida `libnative.dylib`), con **hardened runtime** y las excepciones de entitlements que apliquen (p. ej. `com.apple.security.cs.allow-jit` para el motor Dart, `allow-unsigned-executable-memory` si hace falta).
3. **Notarización**: `notarytool submit` + `stapler staple`; empaquetar `.dmg` (p. ej. `create-dmg`/`hdiutil`).
4. **Build**:
   - Local en el Mac **Ventura** del usuario **si** `flutter doctor -v` da el Xcode por bueno (Ventura soporta hasta **Xcode 15**; Xcode 16 pide Sonoma — verificar que Flutter 3.41 se conforma con 15), **o**
   - **Runner `macos-latest`** en CI (Xcode moderno garantizado; ruta recomendada, independiente del hardware).
5. **Portabilidad del Rust nativo en macOS**: revisar cómo obtienen TLS `reqwest`/`google-cloud-auth` y `ssh2`/`libssh2` en Darwin (Secure Transport vs OpenSSL de Homebrew). Riesgo del **mismo tipo** que en Linux (dylib con dependencia de una OpenSSL que el Mac destino no tiene) → preferir que `libnative.dylib` no dependa de OpenSSL de Homebrew; validar con `otool -L`.
6. **Verificación en Mac limpio**: como en Linux se probó en `debian:12`/`fedora:40` vírgenes, aquí hay que probar en un **Mac limpio** (sin toolchain de dev) que el `.app` notarizado **abre y funciona**. macOS **no se puede contenerizar**, así que esto exige un segundo Mac o el runner de CI + descarga en un Mac real. Es el punto más incómodo de verificar.
7. **CI**: añadir un job `macos-latest` a `.github/workflows/release.yml` (build universal → firma → notarización → `.dmg` → attestations → subir al mismo release). Secrets necesarios: certificado Developer ID (base64) + password, Apple ID / App Store Connect API key para notarytool.

## Decisiones abiertas (a resolver al retomar)

- ¿Sandbox (a) o sin sandbox (b)? — recomendado **(b) sin sandbox** dada la naturaleza de LCC.
- ¿Build local en Ventura o CI `macos-latest`? — recomendado **CI** (garantiza Xcode; no depende del hardware).
- ¿`.dmg`, `.zip` del `.app`, o ambos?

## Fuera de alcance

- Mac App Store (incompatible con quitar sandbox y con lanzar binarios externos).
- Auto-update / Sparkle.
- Este documento **no** es un plan de implementación; es la captura de requisitos. Al retomar: brainstorm de las decisiones abiertas → spec definitivo → plan.

## Lección heredada del release Linux

**"Compila" ≠ "arranca en sistema limpio".** La máquina de desarrollo engaña por tener libs/toolchain instalados. Verificar SIEMPRE en un entorno limpio (en macOS: un Mac sin Xcode/Homebrew, o el artefacto notarizado descargado en un Mac ajeno).
