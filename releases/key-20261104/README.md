# Avata publisher key recovery, 2026-11-04

The original signing private key could not be located. The owner explicitly authorized a new key and a one-time manual trust change. A new RSA-3072 key signs the exact previously validated 1.1.2 runtime bundle; the application bundle itself is unchanged.

Public-key SHA-256: `70c8289ed2e4727725e36c9016e201f287e8f9665fa8ea520f2df4e149a334ac`. Release assets contain only public verification material.

`build_public_release.py` signs locally with the private key file and rejects a different key. Public pre-signed assets are then verified and published by Actions without access to the private key. The pinned original source archive remains unchanged and retains its historical validation results (532 Windows checks).

Existing installations require `Avata_Update_Key_Recovery_1.1.2.zip` once on each PC. Fully stop and close Avata, extract the ZIP, run `Apply_New_Update_Key.cmd`, then launch the existing Avata shortcut. The recovery accepts only the two exact verified updater file versions, holds the existing host/manager/worker mutexes, verifies the new signed release, makes one byte-preserving public-key substitution, and atomically backs up the old updater. It preserves all account data, journals, bundle pointers, trading intent and settings. It does not start a process or send an order. Unknown installations fail with a bounded diagnostic code instead of overwriting code.

This is an explicit manual trust reset, not an update authenticated by the missing old key. Old installations continue to reject the new signature until the recovery is applied. Published release notes must say so. Do not use the original `publish-58.17.8.yml` secret-based workflow for this rotation; use the pre-signed rotation workflow.
