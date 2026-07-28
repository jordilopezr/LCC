# Diseño: Releases firmadas + SBOM en CI (integridad de la cadena de suministro) — seguridad

**Fecha:** 2026-07-28
**Rama:** `ci/signed-releases-sbom`
**Estado:** Aprobado

## Objetivo

Cerrar la amenaza **T8 (integridad de release / cadena de suministro)**: hoy LCC
no publica checksums, ni firmas, ni SBOM, ni procedencia de build. Un usuario que
descarga un `.deb`/`.rpm`/`.AppImage`/`.tar.gz` no tiene forma criptográfica de
verificar **quién** lo construyó, **desde qué commit**, ni **con qué
dependencias**. Este trabajo añade un workflow de GitHub Actions disparado por tag
que **construye los cuatro artefactos Linux en tus contenedores actuales** y les
adjunta: procedencia de build (attestation keyless), un SBOM SPDX (también
atestiguado keyless) y checksums SHA256, publicándolos en un GitHub Release.

El principio rector es el mismo del resto del endurecimiento: **sin teatro**. Una
firma sobre un artefacto construido en el portátil del mantenedor solo prueba "yo
lo hice"; la propiedad real de cadena de suministro (constructor independiente y
atestiguable + procedencia SLSA) solo existe si el build ocurre en CI. Por eso el
build se **mueve a GitHub Actions**.

## Contexto del código actual

- **Remoto:** `https://github.com/jordilopezr/LCC.git` → GitHub Actions disponible.
- **No hay CI:** `.github/` no existe. Los releases se construyen **localmente**
  con `scripts/build_all_containers.sh`, que orquesta dos contenedores podman:
  - `packaging/podman/Containerfile.ubuntu` (ubuntu:20.04) → `.deb`, `.AppImage`,
    `.tar.gz` vía `scripts/package_deb.sh`, `package_appimage.sh`,
    `package_tarball.sh`.
  - `packaging/podman/Containerfile.almalinux` (almalinux:8) → `.rpm` vía
    `scripts/package_rpm.sh`.
- **Los contenedores ya traen todo el toolchain:** Flutter 3.41.1, Rust,
  `flutter_rust_bridge_codegen` 2.11.1, más `appimagetool` (Ubuntu, con
  `APPIMAGE_EXTRACT_AND_RUN=1` para funcionar sin FUSE) y `rpmbuild` (AlmaLinux).
  CI los reutiliza tal cual → **paridad exacta con el build local**.
- **Cada script de empaquetado es autónomo:** hace `flutter clean && flutter pub
  get && flutter_rust_bridge_codegen generate … && flutter build linux --release`
  y luego empaqueta. Produce el artefacto en la raíz del repo (p. ej.
  `lightweight-cloud-connector_26H2_amd64.deb`).
- **`VERSION` está hardcodeado** como `VERSION="26H2"` en los cuatro scripts.
  `ARCH` = `amd64` (deb, tarball) / `x86_64` (rpm, appimage).
- **Lockfiles presentes:** `native/Cargo.lock` (Rust) y `pubspec.lock` (Dart) →
  base sólida para un SBOM que refleje el grafo real de dependencias.
- **macOS** es un build manual aparte (`scripts/build_macos.sh`, requiere Mac);
  **Arch** es una receta fuente (`packaging/arch/PKGBUILD`).

## Decisiones tomadas

| Decisión | Elección |
|---|---|
| Dónde se construye el release | **GitHub Actions**, disparado por tag `v*` (constructor independiente + procedencia) |
| Firma de artefactos | **Solo procedencia** (`actions/attest-build-provenance`, keyless/Sigstore) + `SHA256SUMS`. Sin cosign ni GPG → **cero secretos que gestionar** |
| SBOM: formato y adjunto | **SPDX-JSON** vía **syft** + `actions/attest-sbom` (attestation keyless) + subido al Release |
| Alcance de plataformas | **Solo los 4 artefactos Linux** (deb/AppImage/tarball desde el contenedor Ubuntu; rpm desde AlmaLinux). macOS y Arch fuera |
| Tag → versión | Tag `v26H2` → `VERSION=26H2` (se quita la `v` inicial) → `…_26H2_amd64.deb`. Mantiene los nombres de artefacto actuales |
| Visibilidad del Release | **Draft** (borrador): el workflow lo crea, el mantenedor lo revisa y publica a mano |
| Alcance del SBOM | **Un** SBOM por release, generado escaneando el **árbol de fuentes** (grafo real de crates Rust vía `Cargo.lock` + paquetes Dart vía `pubspec.lock`), atestiguado a los 4 artefactos. Librerías del SO empaquetadas: fuera de v1 |

**Por qué SBOM del árbol de fuentes y no del `.deb`:** escanear el `.deb`/`.rpm`
final capta librerías del sistema, pero **pierde el grafo de dependencias** de
crates y paquetes pub (los lockfiles no van dentro del paquete). El SBOM
relevante para cadena de suministro es el grafo de dependencias de la aplicación,
que vive en los lockfiles. Los 4 artefactos se construyen del mismo fuente →
comparten el mismo grafo de dependencias de app → **un SBOM atestiguado a los
cuatro**. Es honesto: describe los componentes que entraron en el build.

## Arquitectura del workflow

Archivo nuevo: **`.github/workflows/release.yml`**.

- **Disparador:** `on: push` de tags `v*`, más `workflow_dispatch` (con input
  `version`) para ensayar sin tag.
- **Permisos:** `contents: write` (crear release), `id-token: write` +
  `attestations: write` (attestations keyless). **Sin secretos.**

### Job 1 — `build` (matriz: `ubuntu`, `almalinux`), en `ubuntu-latest`

1. `actions/checkout`.
2. Deriva `VERSION` del tag (`v26H2` → `26H2`; en `workflow_dispatch` toma el
   input `version`, con fallback `26H2`).
3. `podman build` de `packaging/podman/Containerfile.<leg>`.
4. `podman run` del contenedor sobre el repo, ejecutando los scripts con
   `VERSION` por entorno:
   - leg `ubuntu`: `package_deb.sh`, `package_appimage.sh`, `package_tarball.sh`.
   - leg `almalinux`: `package_rpm.sh`.
5. `actions/upload-artifact` de los ficheros producidos.

> **Nota de coste (honesta):** cada leg construye la imagen (rustup +
> `cargo install flutter_rust_bridge_codegen` compilado desde fuente + descarga
> de Flutter) y luego el leg Ubuntu hace **tres** builds Flutter+Rust completos
> (un `flutter clean` por script). El release completo puede tardar decenas de
> minutos. Es aceptable para un evento poco frecuente (tag). Cachear las imágenes
> en GHCR y compilar una sola vez por leg son optimizaciones **futuras** (fuera de
> v1) para no tocar la lógica de los scripts y mantener paridad con el build local.

### Job 2 — `release` (needs `build`), en `ubuntu-latest`

1. `actions/checkout` (necesario para que syft escanee el fuente con lockfiles).
2. `actions/download-artifact` de las 4 salidas → `dist/`.
3. `sha256sum dist/* > SHA256SUMS` (nombres base, sin ruta).
4. Instala **syft** (versión fijada) y genera `sbom.spdx.json` escaneando el
   árbol de fuentes → capta crates Rust (`native/Cargo.lock`) y paquetes Dart
   (`pubspec.lock`).
5. `actions/attest-build-provenance` con `subject-path: dist/*` → procedencia
   keyless para los 4 artefactos.
6. `actions/attest-sbom` por artefacto (subject = artefacto, predicate =
   `sbom.spdx.json`) → attestation de SBOM keyless.
7. Crea el GitHub **Release en modo draft** con `dist/*` + `SHA256SUMS` +
   `sbom.spdx.json`, y un cuerpo con las instrucciones de verificación.

## Cambios de soporte

1. **Parametrizar los cuatro scripts de empaquetado:** cambiar
   `VERSION="26H2"` por `VERSION="${VERSION:-26H2}"` en `package_deb.sh`,
   `package_rpm.sh`, `package_appimage.sh`, `package_tarball.sh`. Override por
   entorno para CI; comportamiento local **idéntico** cuando no se define
   `VERSION`. Único cambio en los scripts.
2. **`docs/RELEASES.md`** (nuevo, en inglés, público): cómo se corta un release
   (empujar un tag `v*`) y cómo verifica **cualquiera** una descarga:
   - `gh attestation verify --repo jordilopezr/LCC <fichero>` (procedencia).
   - `gh attestation verify --repo jordilopezr/LCC --predicate-type https://spdx.dev/Document <fichero>` (SBOM).
   - `sha256sum -c SHA256SUMS` (integridad offline).

## Verificación (QA manual del workflow)

1. Empujar un tag de prueba (p. ej. `v26H2-rc1`) → la ejecución termina en verde.
2. El Release **draft** contiene los 4 artefactos + `SHA256SUMS` +
   `sbom.spdx.json`.
3. `gh attestation verify --repo jordilopezr/LCC <artefacto>` pasa (procedencia).
4. `gh attestation verify … --predicate-type https://spdx.dev/Document <artefacto>`
   pasa (SBOM).
5. `sha256sum -c SHA256SUMS` pasa para los 4.
6. `syft` produjo un SBOM no vacío con crates Rust y paquetes Dart reconocibles.

> No hay tests unitarios: el entregable es configuración de CI y un cambio trivial
> de una línea por script. La verificación es la ejecución real del workflow.

## Fuera de alcance (v1, documentado con honestidad)

- **Build/notarización macOS** (requiere runner macOS + Apple Developer ID de
  pago; la procedencia sola no evita el aviso de Gatekeeper).
- **Binario Arch** (el `PKGBUILD` sigue siendo receta fuente).
- **Firmas cosign/GPG de artefactos** (se eligió procedencia keyless).
- **SBOM por artefacto de librerías del SO empaquetadas** (v1 = grafo de
  dependencias de la app, la parte relevante de cadena de suministro).
- **Imágenes de contenedor cacheadas en registry** y **un solo build por leg**
  (optimizaciones futuras).
- **Reproducibilidad bit a bit.**

## Nota de integración

Esta rama sale de `origin/main`, que **no tiene `docs/THREAT_MODEL.md`** (ese doc
vive en `docs/security-hardening` / `security/loopback-listener`). Para **no crear
una tercera copia** ni otro conflicto add/add, aquí **no se toca
`THREAT_MODEL.md`**. La actualización de T8 a "abordado" (referenciando
`.github/workflows/release.yml`) se hace al integrar las ramas de seguridad.
`docs/RELEASES.md` es autónomo de esta rama.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| El build en runners GitHub-hosted es lento (imágenes + 3 builds Flutter) | Evento poco frecuente (solo por tag); cachear imágenes es futuro; se documenta el coste |
| syft escaneando el fuente incluye ruido de dev | Se acota a un SBOM de dependencias de app; formato SPDX estándar; aceptable para v1 |
| `attest-build-provenance`/`attest-sbom` requieren permisos OIDC | Permisos declarados explícitamente en el job (`id-token`, `attestations`, `contents`) |
| Publicar un Release es acción hacia afuera | Se crea en **draft**; el mantenedor revisa y publica a mano; el tag lo dispara el mantenedor |
| Un cambio en los scripts rompe el build local | Único cambio = `${VERSION:-26H2}`, retrocompatible; sin `VERSION` el local no cambia |
| Nombres de artefacto cambian y rompen expectativas | Tag `v26H2` reproduce exactamente `…_26H2_…`; la `v` se quita al derivar `VERSION` |
