use std::path::Path;

/// Supplies the OAuth client secret at build time instead of hard-coding it in
/// the source.
///
/// An installed app cannot keep a secret — PKCE, not this value, is what
/// protects the code exchange — but a secret committed to a public repository
/// is a secret that credential scanners find and that providers revoke, which
/// would break sign-in for everyone running a release. So the value travels
/// with the build and not with the source: official releases inject it, and a
/// build without it simply has no native sign-in and falls back to the gcloud
/// auth engine, which is kept as an escape hatch.
///
/// Taken from `LCC_OAUTH_CLIENT_SECRET`, or from `oauth_client_secret.txt`
/// beside this file (git-ignored) so a local build does not need the variable
/// exported in every shell.
///
/// It is written to a file under `OUT_DIR` rather than emitted as
/// `cargo:rustc-env`: anything a build script prints lands in the build log
/// under `-vv`, and a release workflow's log is public.
fn main() {
    println!("cargo:rerun-if-env-changed=LCC_OAUTH_CLIENT_SECRET");
    println!("cargo:rerun-if-changed=oauth_client_secret.txt");

    let secret = std::env::var("LCC_OAUTH_CLIENT_SECRET")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            std::fs::read_to_string("oauth_client_secret.txt")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        });

    if secret.is_none() {
        // A release that ships without the secret has a broken native sign-in
        // and nothing says so until a user tries it. Worse, cargo caches this
        // build script: a build run once without the secret keeps producing
        // secret-less binaries even after the file is put back, because
        // `rerun-if-changed` on a path that did not exist does not fire when it
        // appears. Measured on 2026-10-12 — it put an empty secret into a
        // packaged .deb. So the release path opts into failing loudly.
        if std::env::var("LCC_REQUIRE_OAUTH_SECRET").is_ok_and(|v| v != "0") {
            panic!(
                "LCC_REQUIRE_OAUTH_SECRET is set but no client secret was supplied. \
                 Set LCC_OAUTH_CLIENT_SECRET or write native/oauth_client_secret.txt. \
                 Refusing to build a release with native sign-in disabled."
            );
        }
        println!(
            "cargo:warning=LCC_OAUTH_CLIENT_SECRET is not set: this build has no native \
             sign-in and falls back to the gcloud auth engine."
        );
    }

    let out = std::env::var("OUT_DIR").expect("cargo always sets OUT_DIR for a build script");
    std::fs::write(
        Path::new(&out).join("oauth_client_secret"),
        secret.unwrap_or_default(),
    )
    .expect("OUT_DIR is writable");
}
