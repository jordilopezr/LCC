# LCC License Worker — Design Spec
**Date:** 2026-04-16
**Status:** Approved

## Overview

A Cloudflare Worker at `lcc.jordilopezr.com` that handles the full license lifecycle: payment processing (Stripe + MercadoPago), license generation, delivery, online activation/validation, and admin management. The existing Ed25519 offline verification in `native/src/license.rs` is preserved and extended — the Worker signs licenses using the same format the app already verifies locally.

---

## Architecture

```
lcc.jordilopezr.com
        │
        ├── Cloudflare Pages       → Static site (landing, /download, /success, /admin UI)
        └── Cloudflare Worker      → Dynamic routes (webhooks, API, admin API, file delivery)
```

**Cloudflare services used:**
| Service | Purpose |
|---------|---------|
| Worker (TypeScript) | Central logic for all dynamic routes |
| D1 (SQLite) | Persistent storage: licenses, activations, download tokens |
| KV (`LCC_REVOKED`) | Fast O(1) revocation lookups |
| R2 | Hosts Free tier binary for download |
| Pages | Static site hosting |
| Resend (HTTP API) | Transactional email (license delivery) |

**Worker Secrets:**
- `ED25519_PRIVATE_KEY` — base64-encoded Ed25519 private key (same key pair as `native/src/license.rs`)
- `STRIPE_WEBHOOK_SECRET` — Stripe webhook signing secret
- `MERCADOPAGO_ACCESS_TOKEN` — MercadoPago API token
- `MERCADOPAGO_WEBHOOK_SECRET` — MercadoPago IPN secret
- `RESEND_API_KEY` — Resend email API key
- `ADMIN_PASSWORD_HASH` — bcrypt hash of admin password
- `ADMIN_JWT_SECRET` — secret for signing admin session JWTs

---

## Routes

```
POST /webhooks/stripe              ← Stripe checkout.session.completed webhook
POST /webhooks/mercadopago         ← MercadoPago payment IPN webhook
POST /api/activate                 ← App calls on Pro license activation
POST /api/validate                 ← App heartbeat every 7 days (Pro only)
POST /api/deactivate               ← App releases a device slot
GET  /download/:token              ← Download license.key (unique token, 3 uses, 24h)
GET  /download/free                ← Download Free tier binary from R2
POST /checkout/stripe              ← Creates Stripe Checkout Session, returns URL
POST /checkout/mercadopago         ← Creates MercadoPago Preference, returns URL
GET  /success                      ← Post-Stripe payment confirmation page
GET  /success/mp                   ← Post-MercadoPago payment confirmation page

GET  /admin                        ← Admin login page (redirects to dashboard if authenticated)
POST /admin/login                  ← Validates credentials, sets JWT cookie
GET  /admin/dashboard              ← License list with filters
GET  /admin/licenses/:id           ← License detail (devices, history)
POST /admin/licenses/:id/revoke    ← Add to KV LCC_REVOKED + update D1
POST /admin/licenses/:id/unrevoke  ← Remove from KV + reactivate in D1
POST /admin/licenses/:id/resend    ← Re-send email + new download token
GET  /admin/logout                 ← Clears session cookie
```

---

## Data Model (D1)

```sql
CREATE TABLE licenses (
    id               TEXT PRIMARY KEY,   -- UUID v4
    tier             TEXT NOT NULL,      -- 'pro' | 'enterprise'
    email            TEXT NOT NULL,
    issued_at        TEXT NOT NULL,      -- YYYY-MM-DD
    expires_at       TEXT,               -- NULL for enterprise (no expiry)
    max_devices      INTEGER NOT NULL DEFAULT 1,
    version          INTEGER NOT NULL DEFAULT 1,
    signature        TEXT NOT NULL,      -- Ed25519 base64url (same format as license.rs)
    payment_provider TEXT NOT NULL,      -- 'stripe' | 'mercadopago'
    payment_id       TEXT NOT NULL,      -- Provider transaction ID
    created_at       TEXT NOT NULL
);

CREATE TABLE activations (
    id           TEXT PRIMARY KEY,       -- UUID v4
    license_id   TEXT NOT NULL REFERENCES licenses(id),
    machine_id   TEXT NOT NULL,          -- SHA-256 hash of hardware identifiers
    activated_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,          -- Updated on each /api/validate
    grace_until  TEXT,                   -- Set when no internet at activation time
    status       TEXT NOT NULL DEFAULT 'active'  -- 'active' | 'grace' | 'revoked'
);

CREATE TABLE download_tokens (
    token      TEXT PRIMARY KEY,
    license_id TEXT NOT NULL REFERENCES licenses(id),
    uses_left  INTEGER NOT NULL DEFAULT 3,
    expires_at TEXT NOT NULL,            -- now + 24h
    created_at TEXT NOT NULL
);

CREATE INDEX idx_licenses_email ON licenses(email);
CREATE INDEX idx_activations_license ON activations(license_id);
```

**KV `LCC_REVOKED`:**
- Key: `license_id`
- Value: `{ reason: string, revoked_at: string, revoked_by: "admin" }`
- Checked before any D1 query in `/api/activate` and `/api/validate`

---

## License Generation

The Worker generates licenses in the exact same format verified by `native/src/license.rs`:

```json
{
  "version": 1,
  "tier": "pro",
  "email": "user@example.com",
  "issued_at": "2026-04-16",
  "expires_at": "2027-04-16",
  "signature": "<base64url Ed25519 over canonical JSON>"
}
```

Canonical message (same as `build_canonical_message` in Rust):
```
{"version":1,"tier":"pro","email":"user@example.com","issued_at":"2026-04-16","expires_at":"2027-04-16"}
```

Enterprise: `expires_at` is omitted (null in DB), canonical message uses `""` for that field — matching the Rust implementation.

---

## License Tiers

| Feature | Free | Pro | Enterprise |
|---------|------|-----|------------|
| Tunnels | 1 | Unlimited | Unlimited |
| Projects | 1 | Unlimited | Unlimited |
| Protocols | SSH/SFTP | All | All |
| Expiry | None | 1 year | None |
| Max devices | — | 1 | 5–100 (set at purchase) |
| Online activation | No | Yes | No (offline only) |
| Upgrade path | — | 2 versions/year, then 50% off upgrade | 2 versions/year |
| Support | None | None | Priority, 1 year |
| Minimum seats | — | 1 | 5 |

---

## Activation & Validation Flow (Pro)

### `POST /api/activate`
Request: `{ license_file: string, machine_id: string }`

```
1. Parse and verify Ed25519 signature of license_file
2. Check KV LCC_REVOKED[license_id] → reject if found
3. Check expires_at → reject if expired
4. Count active activations for license_id in D1
5. If count < max_devices:
     INSERT activation (status='active')
     Response: { status: "active" }
6. If count >= max_devices:
     Response: { status: "error", code: "device_limit" }
```

**App behavior on success:** Sets local flag `validated = true`. Full Pro features.
**App behavior on error/no internet:** Sets `grace_until = now + 15 days`. Full Pro features during grace period. Shows persistent warning to activate online. After grace period expires → reverts to Free.

### `POST /api/validate`
Request: `{ license_id: string, machine_id: string }`
Called every 7 days while app is in use.

```
1. Check KV LCC_REVOKED → if revoked, respond { status: "revoked" }
2. Update activations.last_seen_at in D1
3. Respond { status: "active" }
```

**App on "revoked":** Reverts to Free immediately.

### `POST /api/deactivate`
Request: `{ license_id: string, machine_id: string }`
Removes the device slot so the user can activate on another machine.

### Enterprise — no server calls
Software only verifies Ed25519 signature locally (existing `verify_license_file` in Rust). No `/api/activate` or `/api/validate` calls. Worker only used at purchase time to generate and deliver the license.

**Revocation of Enterprise licenses:** Takes effect only when the user tries to activate on a new device (online check at device registration is not applicable). This is a known limitation of the offline model.

---

## Payment Flow

### Stripe (international)
1. Frontend calls `POST /checkout/stripe` with `{ tier, seats?, promo? }`
2. Worker creates Stripe Checkout Session → returns `{ url }`
3. User completes payment on Stripe
4. Stripe sends `checkout.session.completed` to `POST /webhooks/stripe`
5. Worker verifies Stripe webhook signature
6. Worker generates license, saves to D1, creates download token, sends email

### MercadoPago (Chile)
1. Frontend calls `POST /checkout/mercadopago` with same params
2. Worker creates MercadoPago Preference → returns `{ init_point }`
3. User completes payment on MercadoPago
4. MercadoPago sends IPN to `POST /webhooks/mercadopago`
5. Worker verifies IPN authenticity
6. Same license generation + email flow as Stripe

**Idempotency:** Both webhook handlers check `payment_id` uniqueness in D1 before generating a license — duplicate webhooks are safely ignored.

---

## Email Delivery (Resend)

On successful payment:
- **To:** buyer's email
- **Subject:** "Tu licencia LCC — [tier]"
- **Body:** Instructions for placing `license.key`, download link (unique token), support contact
- **Attachment:** `license.key` (the generated JSON license file)

The download link is valid 24 hours with 3 uses maximum.

---

## Download Routes

**`GET /download/:token`** (license file):
1. Look up token in D1
2. Check `expires_at` and `uses_left > 0`
3. Decrement `uses_left`
4. Fetch license from D1, return as `application/octet-stream` with `Content-Disposition: attachment; filename="license.key"`

**`GET /download/free`** (Free binary):
- Redirect to R2 signed URL for the latest `.tar.gz`
- No auth required
- Version updated by uploading new binary to R2 manually

---

## Admin Panel

**Authentication:** `ADMIN_PASSWORD_HASH` (bcrypt) + `ADMIN_JWT_SECRET`. JWT cookie, 8h expiry, HttpOnly + Secure + SameSite=Strict.

**Dashboard features:**
- License table: email, tier, purchase date, payment provider, status (active/revoked/expired)
- Filters: tier, status, provider
- Search: by email or payment_id
- Per-Enterprise row: active device count vs max_devices

**Revocation:**
- Writes `LCC_REVOKED[license_id]` to KV with reason + timestamp
- Updates `licenses.status = 'revoked'` in D1
- Pro users see effect on next `/api/validate` (max 7 days)
- Enterprise users: no immediate effect (offline model limitation — flagged in UI)

**Resend:**
- Creates new download token (3 uses, 24h)
- Sends new email with license attachment + new link

---

## Site Structure (Cloudflare Pages)

```
/                    → Landing page: features, tier comparison, pricing, buy buttons
/download            → Free download page
/success             → Post-Stripe confirmation + setup instructions
/success/mp          → Post-MercadoPago confirmation + setup instructions
/admin               → Admin panel (SPA served by Pages, API calls to Worker)
```

**Payment provider selection:** Manual — the pricing page shows two buy buttons per paid tier: "Comprar con Stripe" and "Comprar con MercadoPago". No geolocation.

---

## Error Handling

| Scenario | Response |
|----------|----------|
| Webhook signature invalid | 400 Bad Request, no license generated |
| Duplicate payment_id | 200 OK (idempotent), no duplicate license |
| Device limit reached | `{ status: "error", code: "device_limit" }` |
| License revoked | `{ status: "revoked" }` |
| Download token expired/exhausted | 410 Gone |
| Admin wrong password | 401, no JWT issued |
| Ed25519 signature invalid | `{ status: "error", code: "invalid_license" }` |

---

## Out of Scope

- Automated version detection for Free download (manual R2 upload)
- Upgrade flow automation (handled manually or as future feature)
- Multi-language site (planned for 26H2)
- MercadoPago subscription/recurring billing (annual renewal is manual repurchase)
