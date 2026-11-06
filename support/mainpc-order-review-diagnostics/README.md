# Main PC order review diagnostics patch

Base source: Avata 1.1.6 / bundle 58.17.12.

## Finding

A broker-rejected NEW order is replayed as SIM_ORDER_REJECTED, which becomes LIVE_ORDER_REVIEW. This deliberately holds live execution. The current event stream does not retain the broker rejection reason code, so the exact reason for the Nov 6 rejection is not recoverable from the shared diagnostic tab.

## Changes

- Preserve a validated broker reject code on a reconciled zero-fill rejection.
- Carry a safe reason code through the live status and manager fault event, including the diagnostic Sheet and Telegram event.
- Exclude repetitive OK/LISTENING rows from the 300-entry cloud diagnostics window so important events remain visible.
- Add synthetic tests for code allowlisting, redaction and important-event retention.

The patch keeps the fail-safe review hold and does not automatically retry or resume an order. This is a source-only review patch, not a signed update package. Run the Windows PowerShell 5.1 regression suite and prepare a newly signed release before installing or publishing it.
