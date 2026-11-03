# Avata 1.1.1 — prepared, not deployed

Internal build: 58.17.7. Candidate: bundle-0af5ff1d162133624108e1f0.

The midnight reader previously treated a fresh previous-day input cache as an immediate fault. This candidate records a verified day transition, requests one immediate input refresh, and continues only after today's input and two fresh ledger confirmations. It preserves existing same-process operator intent; a disarmed or restarted application is not armed by the transition.

Normal transition progress is distinguished from missing/stale input, identity changes, network failures and uncertain orders. A watchdog reports a transition that fails to finish; it does not impose a fixed delay. Reads crossing midnight discard mixed-date snapshots. Recovery after a reported live fault emits a recovery notice.

Manager logs now retain bounded diagnostic identifiers, and the diagnostic viewer displays live-read errors. Main PC desktop mode and miniPC tray mode remain independent; the main PC retains full live-trading capability.

## Verification
- 308 local Windows PowerShell 5.1 checks passed, including 42 day-transition checks.
- Hosted Windows: 18 tray and 4 full desktop startup checks pending.
- All checks use isolated synthetic data and blocked broker order calls.
- Signed package and manifest validated with the existing updater.
- Real overnight trading has not been tested or activated.

## Deployment hold
Prepared at the user's request for review and application on the evening of 2026-11-04 (KST).
No GitHub release is published by this branch or its workflow. The latest automatic-update feed stays at 1.0.1 / 58.17.6. Neither installed PC is modified.
Do not run the main-PC setup until the reviewed candidate is explicitly published for application.
