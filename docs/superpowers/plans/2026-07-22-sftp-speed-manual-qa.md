# Manual QA — SFTP parallel transfers (27H1)

Run with the app's default engine (gcloud tunnel), no env vars needed.

- [ ] Upload a >100 MB file; the bar advances and the transfer completes ≥3x
      faster than before (~0.7 MB/s baseline).
- [ ] `sha256sum` of the uploaded file matches the local one (run on the VM).
- [ ] Download the same file back; progress bar shows; checksum matches.
- [ ] Upload the offline-bundle folder (12 files, ~250 MB): global bar shows
      "N% — X/Y MB, F/12 archivos" and total time is ~1–1.5 min.
- [ ] Small file (<8 MB) uploads still work (single-connection path).
- [ ] Kill the tunnel mid-upload: the app shows an error, and the partial
      remote file was deleted (verify on the VM).
- [ ] Close the dialog mid-upload: app does not crash (same behavior as before).
