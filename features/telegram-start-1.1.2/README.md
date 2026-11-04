# Avata 1.1.2 Telegram start candidate

When persistent automatic start is off and the current process is ready, the linked Telegram chat receives “실주문 시작하시겠습니까?” with Yes / No buttons. Only the user verified during Telegram pairing may approve. A Yes is a one-time request for the named PC and running account/strategy; it does not enable persistent automatic start. A confirmed activation, including an existing local or automatic start, sends “실주문 시작합니다.”

No leaves trading off and suppresses repeated prompts. The result offers “준비 상태 다시 확인”, which only requests a fresh Yes / No invitation. Invitations expire after ten minutes. A separate one-use handoff expires after twenty seconds. The UI and account worker recheck the current account reconciliation, orders, release/manager health, source identity, automatic preference, pairing, and stop/update state. Stale, replayed, forwarded, wrong-user, wrong-chat/topic and previous-process callbacks cannot start trading. Local stop supersedes a queued Telegram decision. Failure to activate is reported without an automatic retry.

Telegram runs in its own background runspace; network waits do not block account reads or the UI. Messages contain PC mode and symbol, never account numbers, broker credentials, bot tokens or callback authorization data. Diagnostics contain only time and bounded control state. No strategy sizing, broker transport, ledger, cash handling or automatic-start preference is changed.

## Operation limits

- Use one active control consumer per Telegram bot. Main PC and miniPC are supported as alternatives. If both need interactive controls simultaneously, pair separate bots; Telegram getUpdates is one shared queue and two independent clients cannot reliably consume it. A device-specific nonce prevents a callback from starting the wrong process, but is not a cross-PC trading lock.
- No remote stop/cancel or persistent automatic-start toggle is added in this change.
- Tests use synthetic Telegram responses and isolated account fixtures. End-to-end delivery/button clicks with the user's real bot remain an installation check.
- This is an unpublished source/verification candidate. There is no signed update feed or installer in this archive. It must not be copied over an active installation. Existing 1.1.1 remains unchanged.

## Verification

Run `Run-Checks.ps1` using Windows PowerShell 5.1. It parses the complete bundle and runs 331 previous core/day-transition/API/host checks plus 78 Telegram start checks and 4 background-worker checks. The isolated GitHub-hosted Windows job additionally runs 18 tray and 4 desktop startup checks. No real broker request, order, Telegram message, or credential is used.

Official Telegram API references: https://core.telegram.org/bots/api#inlinekeyboardmarkup, https://core.telegram.org/bots/api#callbackquery, https://core.telegram.org/bots/api#getupdates.
