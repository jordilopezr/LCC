//! Manual end-to-end check of LCC's own token session (SG-D / D3).
//!
//! Usage: LCC_AUTH_ENGINE=native cargo run --example auth_native
//!
//! Ensures a stored session exists — signing in through the browser only when
//! there is none or the stored refresh token was rejected — and then asks the
//! REST client for an access token through the native path.
//!
//! Run it TWICE: the second run must NOT open a browser. That is the proof the
//! refresh token in the keyring is doing its job. Secrets are never printed in
//! full: only a short prefix of the access token.

fn main() {
    let result = native::logging::block_on(async {
        let email = native::oauth::ensure_signed_in().await?;
        let auth = native::gcp_rest_client::GcpAuthClient::get_or_init()?;
        let token = auth.get_access_token().await?;
        Ok::<_, anyhow::Error>((email, token))
    });

    match result {
        Ok((email, token)) => {
            let prefix: String = token.chars().take(12).collect();
            println!("✓ Session ready for: {}", email);
            println!("  engine:       {:?}", native::oauth::auth_engine());
            println!("  access token: {}… ({} chars)", prefix, token.len());
        }
        Err(e) => {
            eprintln!("✗ Native auth failed: {}", e);
            std::process::exit(1);
        }
    }
}
