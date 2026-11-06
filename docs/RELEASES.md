# Releasing LCC

LCC releases are built, attested, and published by GitHub Actions
(`.github/workflows/release.yml`) — not on a maintainer's machine. Every
artifact carries a keyless (Sigstore-backed) build-provenance attestation and
an SPDX SBOM attestation. There is no signing key to manage.

## Versions and channels

A release is identified by four values in `lib/src/version.dart`: edition
(`kEdition`, `YYH1`/`YYH2`), update (`kUpdate`), channel (`kChannel`, preview
or stable) and build (`kBuild`, `YYYYMMDD.n`). The tag is derived from them:

| Channel | Tag | Example |
|---|---|---|
| Preview | `v<edition>-preview.<build>` | `v27H1-preview.20261105.56` |
| Stable | `v<edition>` | `v27H1` |
| Stable security patch | `v<edition>u<update>` | `v27H1u2` |

The lifecycle:

- Each **preview** iteration bumps `kBuild`; `kUpdate` stays `0`.
- The edition's first **stable** sets `kChannel` to stable. Each security
  patch after it bumps `kUpdate` only — the build stays the same.
- Once an edition ships stable, previews move to the **next** edition
  (27H1 stable → `v27H2-preview.*`), and the previous stable edition is
  closed: it gets no more patches, and users upgrade to receive fixes.

Versions are ordered by edition, then channel (preview before stable), then
update, then build. The in-app update checker relies on this order and reads
it from the tag, so the workflow enforces all of the above
(`scripts/check_release_version.sh`, which you can also run locally) before it
builds anything:

- the tag is well-formed and matches `lib/src/version.dart`;
- it is newer than every published release of its channel;
- a preview's edition has not shipped stable yet;
- a stable patch has a published stable of its edition to patch, keeps its
  build, and belongs to the current stable edition.

Older tags predate this scheme; the checks ignore the ones that don't fit it
(such as `v26H2u1-rc2`).

## Cutting a release

1. Make sure `main` is at the commit you want to ship, with
   `lib/src/version.dart` bumped as above.
2. Push the tag that `version.dart` describes:

   ```bash
   TAG="v$(scripts/check_release_version.sh expected)"
   git tag "$TAG"
   git push origin "$TAG"
   ```

3. The `Release` workflow runs (tens of minutes: it rebuilds the container
   images and does a full Flutter + Rust build per artifact). It produces,
   for e.g. `v27H1-preview.20261105.56`:
   - `lightweight-cloud-connector_27H1-preview.20261105.56_amd64.deb`
   - `lightweight-cloud-connector_27H1-preview.20261105.56_x86_64.AppImage`
   - `lightweight-cloud-connector_27H1-preview.20261105.56_amd64.tar.gz`
   - `lightweight-cloud-connector-27H1.preview.20261105.56-1.x86_64.rpm`
   - `lightweight-cloud-connector_27H1-preview.20261105.56_macos-universal.zip`
   - `SHA256SUMS`
   - `sbom.spdx.json`
4. A **draft** GitHub Release is created with those assets, already marked
   **pre-release** for a preview tag. Review it, then publish it manually from
   the Releases page — without changing the pre-release checkbox.

To dry-run the build and attestations without creating a release, use
**Run workflow** (`workflow_dispatch`). Leave `version` empty to use the one
`lib/src/version.dart` describes. Everything runs except the release-creation
step; a lifecycle violation (typically: that version is already published) is
reported but does not fail a dry run.

## What the in-app update checker sees

LCC asks `api.github.com/repos/jordilopezr/LCC/releases` shortly after start
and every 12 hours (Settings → Updates). So, for releases:

- **Publishing is announcing.** A draft is invisible to the checker; users
  hear of a release within about 12 hours of it being published.
- **The tag decides the version and the channel.** A tag that does not fit
  the scheme above is ignored. A release with a stable tag but the
  pre-release box ticked is treated as a preview, so it never reaches
  stable-channel users.
- **The link is the release page** (`github.com/jordilopezr/LCC/releases/…`);
  LCC opens nothing else and downloads nothing.
- **Publishing a new edition's stable** tells everyone still on the previous
  stable edition that it no longer gets security patches. That notice cannot
  be skipped, only put off, so ship it when the new edition is ready for
  them.
- **Deleting a release** withdraws it: on their next check, users who had not
  upgraded stop being offered it.

### Turning the check off when packaging

A package that delivers LCC's updates itself should turn the check off:

```bash
# Building from source
flutter build linux --release --dart-define=LCC_DISABLE_UPDATE_CHECK=true

# Repackaging a release build: set it in the launcher
LCC_DISABLE_UPDATE_CHECK=1 exec /opt/lightweight-cloud-connector/lightweight-cloud-connector "$@"
```

Any value other than empty, `0` or `false` turns it off. LCC then sends no
request, ignores any release list stored by an earlier run, and Settings →
Updates says the package provides updates. `packaging/arch/PKGBUILD` does
this in its `/usr/bin` launcher. The packages this workflow builds keep the
check on: their updates come from GitHub Releases.

## Verifying a download

Anyone can verify a downloaded artifact against this repository. The
`gh attestation verify` command requires **GitHub CLI ≥ 2.49** (older versions
lack the `attestation` subcommand):

```bash
# Build provenance — proves which repo, commit, and workflow built it
gh attestation verify --repo jordilopezr/LCC ./lightweight-cloud-connector_26H2_amd64.deb

# SBOM — the dependency graph that went into the build
gh attestation verify --repo jordilopezr/LCC \
  --predicate-type https://spdx.dev/Document/v2.3 \
  ./lightweight-cloud-connector_26H2_amd64.deb

# Offline integrity — run from the directory holding the downloads + SHA256SUMS
sha256sum -c SHA256SUMS
```

The SBOM is generated by scanning the source tree, so it reflects the real
Rust crate graph (`native/Cargo.lock`) and Dart package set (`pubspec.lock`).
Operating-system libraries bundled by the individual packages are out of scope
for the current SBOM.

## Not covered by CI

- **macOS notarization.** CI builds the macOS Universal Binary (job `build-macos`,
  on the `macos-15-intel` runner) and attests it like the Linux artifacts, but
  signs it ad-hoc: real macOS trust needs a paid Apple Developer ID +
  notarization.
- **Arch** — `packaging/arch/PKGBUILD` remains a source recipe users build.
