# Avata 1.1.2 automatic update — published

Published on 2026-11-04 as [v1.1.2](https://github.com/crosnuu12/Avata-kor-releases/releases/tag/v1.1.2), internal build 58.17.8. [Publication run 41846886818](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/41846886818) passed public versioned and latest-feed download, signature, package hash and manifest validation.

The exact application candidate passed 532 Windows PowerShell 5.1 checks in [run 41840405969](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/41840405969). Candidate SHA-256: `82d52ac404ca2929c718ccc0a5015790f5e09252b3bdbd9d68f6532d4d7b7f32`.

Existing PCs require the owner-authorized one-time public-key recovery. Fully close Avata, extract `Avata_Update_Key_Recovery_1.1.2.zip`, run `Apply_New_Update_Key.cmd`, then relaunch the existing shortcut. Old installations reject the new signature until recovery is applied. Public-key SHA-256: `70c8289ed2e4727725e36c9016e201f287e8f9665fa8ea520f2df4e149a334ac`.

Recovery passed 33 Windows checks in [run 41846556672](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/41846556672): exact updater variants, atomic backup of the old updater, rollback, file locks, tampering and preservation of synthetic user data. No real installed PC, broker order or live spreadsheet was accessed.

The release implementation is in `releases/key-20261104/` and `.github/workflows/rotate-update-key.yml`. This supersedes the original-key preparation in this directory and the old `publish-58.17.8.yml` workflow.
