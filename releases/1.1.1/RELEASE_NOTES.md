# Avata 1.1.1 (58.17.7) — host repair

The previous-day input transition is tracked without relabeling old data or changing market hours. Trading remains blocked until today's input and two account reconciliations are available.

This release also:
- Retries only Windows file sharing/lock violations during atomic manager/host writes, for a bounded total wait of about one second. Persistent, permission and disk errors still fail.
- Records redacted host exception type, line and numeric Windows code in the existing relay's Stage column; raw exception messages are excluded.
- Preserves bounded broker API codes and request stages in live and read logs. Unknown API failures and cash mismatches still block orders.
- Includes a transactional host repair kit for installed 58.17.0, 58.17.6, or this exact 58.17.7 bundle. It requires all app processes closed, DISARMED, no pending commands/open/unknown orders, and a reconciled recorded close. It preserves account data, credentials, live-start consent, update preferences, and window preferences. The application must reconcile fresh data after restart.
- Backs up all three host scripts and settings; interruption restores original bytes. No process kill, broker request, order, or consent change is performed by the installer.

The file-sharing failure was reproduced in the old writer. It is a plausible cause of the observed HOST_ERROR, not a confirmed attribution of the historical incident, which lacked detailed exception logs.

Windows PowerShell 5.1 and hosted Windows: 331 core/transition/host/API + 56 installer + 18 tray + 4 desktop checks passed (409 total). The original 58.17.0 updater verified the signature and exact payload. Validation: https://github.com/crosnuu12/Avata-kor-releases/actions/runs/41730346412 . Real overnight operation after installation remains to be observed.

Download and completely extract Avata_Repair_1.1.1.zip. If Windows marks the download as blocked, use ZIP Properties → Unblock before extraction. Close Avata normally while DISARMED and reconciled, then run Repair_Avata.cmd. After SUCCESS: UPDATE_STAGED, start the existing Avata shortcut and verify version 1.1.1, READ_OK and CURRENT. Confirm live-start status separately.

This kit is required to replace the host scripts; the normal application auto-update does not replace those scripts. Main-PC window setup remains optional and separate; mini-PC tray preferences are preserved.
