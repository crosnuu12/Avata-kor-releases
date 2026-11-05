# Avata 1.1.6 validation

Published and verified on 2026-11-05 at 19:06 KST (10:06 UTC).

- Product version: **1.1.6**; bundle version: **58.17.12**.
- Release commit: `22875707919f1768df67969ab5c5e542b7197738`.
- Bundle ID: `bundle-11fc76ec177e6d55f3a300e6`.
- [Corrected candidate CI](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/42007210196): passed.
- [Main verification and publication](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/42007548065): passed. Windows PowerShell 5.1 completed **800 synthetic checks**, including **74 asset checks**; the source-retrieval suite passed **10 tests**.
- [Current-source retrieval CI](https://github.com/crosnuu12/Avata-kor-releases/actions/runs/42007548190): passed.
- The final review fixed a header-format range regression. Eight checks now cover header and base-format bounds during initial publication, growth, shrink and corrupt-cache repair.
- The publisher downloaded the public version-specific feed and the latest feed using the actual updater, then verified the signatures, package hashes and manifest identity.

[Published release](https://github.com/crosnuu12/Avata-kor-releases/releases/tag/v1.1.6) · [Signed update feed](https://github.com/crosnuu12/Avata-kor-releases/releases/latest/download/avata-update.json)

Published archive SHA256: `a2ae7326cbdd89b38555b6d08ca684ae93d702d0d783855efb1f89763651bdf7`.
Runtime package SHA256: `f468e61982eedf59fa7a352fbb9fe4fb77b984dd4b850e580325153c15d6f9ba`.

The immutable verification ZIP contains pre-run candidate metadata; the CI runs above are the completed validation record. No real account credentials, broker orders or Telegram messages were used in testing. Publication does not establish installation on a user PC; confirm the installed bundle through current diagnostics. Mobile loading time remains unmeasured.
