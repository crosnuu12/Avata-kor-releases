# Avata 1.1.3 release status

Published on 2026-11-05 at 01:37:22 UTC. Internal version: `58.17.9`.

- Windows PowerShell 5.1: 564 checks passed, including 32 diagnostic checks, 18 tray checks and 4 full desktop startup checks.
- Reviewed source commit: `f035bab8f7f93f36d1f99151ac751463aa01258c`.
- Release merge: `861798eb16bce430860596df00edf990a09107ef`.
- Verified publication: [Actions run 41949549780](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/41949549780), public-download verification job `126990453462`.
- Public update feed signature, downloaded package hash and bundle identity verified after publication.

| Artifact | SHA-256 |
| --- | --- |
| Runtime package | `4c0d4e8621c71160810aa3437c6ed59dbf20ec06b844ed2eb3888fb1d122258e` |
| Bundle manifest | `378a7336de1b997d8cb8f01d3dad3bdf145690ebf162f7296a09a18bd6d1bca5` |
| Verification kit | `f739e9c21369c69cd1dcccd14604a6a70b05d6ca7e62068f362940af7f525522` |

The manager starts a separate diagnostic worker automatically when spreadsheet integration is enabled. Normal updates take approximately 20–30 seconds; transport failures back off to 120 seconds. Device ownership prevents a different installation from overwriting the diagnostic tab. When the PC, manager or internet is unavailable, the last collection timestamp remains visible. Publication is verified independently from each installation's eventual uptake.
