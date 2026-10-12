# Manual QA — Account dialog error reconciliation

Open the Account Management dialog and force error states.

- [ ] Trigger a permission/auth error (e.g. an unauthenticated or permission-denied GCP action) → the dialog's red error box shows the unified `appError*` message (e.g. the same permission-denied text used elsewhere in the app), not a raw Rust string.
- [ ] Trigger an unknown/unclassified error → the box shows the generic wrapper with the raw detail (`appErrorGeneric`), not a blank or a stale "An error occurred. Please check your configuration."
- [ ] Switch to Spanish and repeat one case → the message is the Spanish `appError*` text.
- [ ] Normal (no error) flow: the red error box does not appear.
