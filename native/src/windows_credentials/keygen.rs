//! RSA key generation and decryption for Windows credential generation.
//!
//! This module handles the cryptographic operations needed to generate
//! Windows VM passwords via the Google Compute Engine guest agent API.

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use num_bigint_dig::BigUint;
use rand::rngs::OsRng;
use rsa::{
    Oaep,
    RsaPrivateKey, RsaPublicKey,
    traits::PublicKeyParts,
};
use sha1::Sha1;

/// RSA key pair used for Windows credential generation.
pub struct RsaKeyPair {
    pub private_key: RsaPrivateKey,
    pub public_key: RsaPublicKey,
}

impl RsaKeyPair {
    /// Generate a new RSA key pair with 2048 bits.
    ///
    /// Uses the operating system's cryptographically secure random number generator.
    pub fn generate() -> Result<Self, String> {
        let bits = 2048;
        let private_key = RsaPrivateKey::new(&mut OsRng, bits)
            .map_err(|e| format!("Failed to generate RSA private key: {}", e))?;
        let public_key = RsaPublicKey::from(&private_key);

        Ok(RsaKeyPair {
            private_key,
            public_key,
        })
    }

    /// Get the modulus of the public key as a base64-encoded string.
    ///
    /// The modulus is encoded in big-endian format as required by
    /// the Google Compute Engine guest agent.
    pub fn modulus_base64(&self) -> String {
        let modulus: BigUint = self.public_key.n().clone().into();
        let modulus_bytes = modulus.to_bytes_be();
        BASE64.encode(&modulus_bytes)
    }

    /// Get the public exponent as a base64-encoded string.
    ///
    /// Typically this is 65537 (0x10001) encoded as base64.
    pub fn exponent_base64(&self) -> String {
        let exponent: BigUint = self.public_key.e().clone().into();
        let exponent_bytes = exponent.to_bytes_be();
        BASE64.encode(&exponent_bytes)
    }

    /// Decrypt an encrypted password using the private key.
    ///
    /// The Google Compute Engine guest agent encrypts the password using
    /// RSA-OAEP with SHA-1 padding.
    ///
    /// # Arguments
    /// * `encrypted_base64` - Base64-encoded encrypted password from the guest agent
    ///
    /// # Returns
    /// The decrypted password as a UTF-8 string
    pub fn decrypt_password(&self, encrypted_base64: &str) -> Result<String, String> {
        let encrypted_bytes = BASE64.decode(encrypted_base64)
            .map_err(|e| format!("Failed to decode base64 encrypted password: {}", e))?;

        // SECURITY NOTE (M9 — SHA-1 in RSA-OAEP, accepted constraint):
        // SHA-1 is mandated by the GCP Windows Guest Agent protocol and cannot be
        // changed without breaking compatibility with all Windows VMs on GCP.
        // Risk is mitigated by:
        //   - Ephemeral RSA key pair (generated per-session, never written to disk)
        //   - 5-minute expiration on the key request sent to the VM metadata
        //   - Encrypted channel protected by GCP IAP + TLS 1.3
        //   - No known practical chosen-plaintext attack against RSA-OAEP/SHA-1
        // Reference: https://cloud.google.com/compute/docs/instances/windows/automate-pw-generation
        let padding = Oaep::new::<Sha1>();
        let decrypted_bytes = self.private_key.decrypt(padding, &encrypted_bytes)
            .map_err(|e| format!("Failed to decrypt password: {}", e))?;

        String::from_utf8(decrypted_bytes)
            .map_err(|e| format!("Decrypted password is not valid UTF-8: {}", e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keypair_generation() {
        let keypair = RsaKeyPair::generate();
        assert!(keypair.is_ok());
        let keypair = keypair.unwrap();

        // Modulus should be non-empty and properly base64 encoded
        let modulus = keypair.modulus_base64();
        assert!(!modulus.is_empty());
        assert!(BASE64.decode(&modulus).is_ok());

        // Exponent should be non-empty
        let exponent = keypair.exponent_base64();
        assert!(!exponent.is_empty());
        assert!(BASE64.decode(&exponent).is_ok());
    }

    #[test]
    fn test_modulus_length() {
        let keypair = RsaKeyPair::generate().unwrap();
        let modulus_bytes = BASE64.decode(&keypair.modulus_base64()).unwrap();

        // 2048-bit key should have a modulus of approximately 256 bytes
        // (could be 255-257 depending on leading zeros)
        assert!(modulus_bytes.len() >= 255 && modulus_bytes.len() <= 257);
    }

    #[test]
    fn test_exponent_value() {
        let keypair = RsaKeyPair::generate().unwrap();
        let exponent_bytes = BASE64.decode(&keypair.exponent_base64()).unwrap();

        // Default RSA exponent is 65537 (0x010001)
        let exponent = BigUint::from_bytes_be(&exponent_bytes);
        assert_eq!(exponent, BigUint::from(65537u32));
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let keypair = RsaKeyPair::generate().unwrap();
        let test_password = "TestPassword123!";

        // Encrypt using public key (simulating what the guest agent does)
        let padding = Oaep::new::<Sha1>();
        let encrypted = keypair.public_key
            .encrypt(&mut OsRng, padding, test_password.as_bytes())
            .unwrap();
        let encrypted_base64 = BASE64.encode(&encrypted);

        // Decrypt using our method
        let decrypted = keypair.decrypt_password(&encrypted_base64).unwrap();
        assert_eq!(decrypted, test_password);
    }
}
