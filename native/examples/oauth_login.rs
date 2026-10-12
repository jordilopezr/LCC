//! Manual end-to-end check of LCC's own OAuth sign-in (SG-D / D1).
//!
//! Usage: cargo run --example oauth_login
//!
//! Opens the browser, completes the authorization-code + PKCE flow against
//! LCC's OAuth client and prints who signed in. Secrets are never printed in
//! full: the refresh token is reported only as present/absent and the access
//! token only by a short prefix.

fn main() {
    let result = native::logging::block_on(native::oauth::interactive_login());

    match result {
        Ok(tokens) => {
            let prefix: String = tokens.access_token.chars().take(12).collect();
            println!("✓ Signed in as: {}", tokens.email);
            println!("  refresh token: {}", if tokens.refresh_token.is_empty() { "MISSING" } else { "received" });
            println!("  access token:  {}… ({} chars)", prefix, tokens.access_token.len());
            println!("  expires in:    {} s", tokens.expires_in_secs);
        }
        Err(e) => {
            eprintln!("✗ Sign-in failed: {}", e);
            std::process::exit(1);
        }
    }
}
