# Avata 1.1.2 automatic-update preparation

The exact application candidate passed 532 Windows PowerShell 5.1 checks in [run 41840405969](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/41840405969), commit `cd8576d58bc897fb1174186df0830daadc9c7fd1`.

Candidate SHA-256: `82d52ac404ca2929c718ccc0a5015790f5e09252b3bdbd9d68f6532d4d7b7f32`.

The packaging script uses only the verified bundle's 12 allowlisted scripts and its manifest. Its unsigned preparation output is not an update feed and must not be installed manually. The publishing workflow requires the original 3072-bit RSA private key matching the public key already pinned by installed applications. A new or unrelated key is rejected; signature validation is never disabled.

For publication, the existing private key must be provided to the repository's `AVATA_UPDATE_SIGNING_KEY` Actions secret (RSA XML or PEM). An encrypted PEM may use `AVATA_UPDATE_SIGNING_PASSWORD`. Do not commit either value or paste it into an issue/PR. The private key remains available only to the signing step and is never included in uploaded artifacts.

After the key is available, run `Publish Avata 1.1.2 automatic update` on `main`. The workflow checks the successful source validation, verifies the signed package with the original updater, publishes the versioned download, verifies it over HTTPS, and only then promotes the product release to the automatic-update channel. It verifies the latest feed again after promotion. Existing published release assets are never overwritten.

Current deployment is blocked on the original signing key; the latest public automatic-update feed remains 1.1.1. Source publication and automatic-update publication are separate steps.
