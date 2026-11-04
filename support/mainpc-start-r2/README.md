# Main-PC start helper R2 for Avata 1.1.1

This fixes a launcher prerequisite that stopped startup with AVATA_INSTALLATION_MISSING when Avata_kor.exe was not found. The helper now resolves the current Windows user's profile and known LocalApplicationData folders, requires exactly one complete existing host, and uses the unchanged verified bootstrap script to start that host. It never searches another user's installation or copies credentials.

The helper validates the installed bundle with the original bootstrap before changing desktop window preferences. It does not create live-order consent or submit an ARM, STOP, or broker order command. Startup errors are recorded as bounded codes and checked paths in MainPC-start-result.json; no tokens, account data, or raw exception messages are included.

19 isolated Windows PowerShell 5.1 checks passed, including missing outer launcher, redirected folders, ambiguous/cross-user installs, disabled updates, altered bundle, duplicate-process rejection, consent/ledger preservation, and preference rollback. Inspection of the existing local 58.17.0 installation also succeeded without starting the real application. The remote screenshot's exact environment mismatch remains unconfirmed until its own diagnostic is available.

Download Avata_MainPC_1.1.1_Start_R2.zip, extract it, then run Avata_MainPC_1.1.1.cmd. The first line must say START HELPER R2. STARTED means the host startup request succeeded; verify product 1.1.1 and READ_OK in the real application. The main application's published 1.1.1 assets and signed update feed remain unchanged.

ZIP SHA-256: 2d1d63667f60fcea3c50adb5686786bdc7c9d1f7eeb06db052fb489ad292c317
Bootstrap SHA-256: e4d90f1d78684ac5fdfb39d582091bed39501cc5a19df0d66357649d43607a49
