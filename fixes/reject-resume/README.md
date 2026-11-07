# Confirmed rejected-order manual resume candidate

Base: Avata 1.1.8 / 58.17.14. This is a source candidate, not a signed release or an installer. Installed account state is never read or changed by this package.

A prior goal ending in a rejected NEW order caused every subsequent Step to disarm an explicitly restarted session; the planner also refused all new intents. Date changes did not clear either gate.

The candidate lets an explicit local ARM acknowledge the exact existing, broker-identified, zero-fill terminal rejections. It preserves the rejection ledger, resets account confirmation proof, and requires two fresh reconciliations before dispatch. Off-hours retain ARMED with LIVE_MARKET_WAIT. Reopening still requires fresh market, account, strategy and quota checks. New rejections disarm again. Uncertain orders, fills in the rejected goal, missing broker identity, unresolved quantities and changed evidence remain blocked. Automatic or Telegram start does not grant this new acknowledgment.

Apply-Patch.py requires the exact published base Core hash and verifies the resulting candidate hash. It edits only the extracted candidate's Core. No release manifests, update feeds, installed files, credentials, balances or order books are changed.

Windows validation: extract the pinned Avata_58.17.14_Verification.zip into a new temporary folder, run `python Apply-Patch.py <folder>`, copy Test-RejectResume.ps1 into the folder, then run it with Windows PowerShell 5.1. Run the existing Run-Checks.ps1 suite on the same isolated candidate. The GitHub workflow automates these steps using synthetic accounts and blocked real transports.

Production deployment requires a separately versioned and validated bundle. Do not copy this Core over a signed installed bundle.
