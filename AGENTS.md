# Installing Vella (for coding agents)

Your user asked you to install Vella: a menu-bar app for offline dictation and live transcription on their Mac. Do this, then tell them what you did.

1. **Check.** Apple Silicon Mac, macOS 14 or newer. The prebuilt app needs nothing else. If a check fails, the installer prints the problem; pass it to the user and stop.
2. **Install.** From this repository: `scripts/install.sh`. It downloads the prebuilt app for this version with curl, verifies its SHA-256 and signature, puts it in `~/Applications`, starts it and waits until it is ready. It prints a few short lines and ends with `ready: …`. Never download the zip through a browser. If it says Vella is recording, transcribing or loading, wait a minute and run it again; it changed nothing.
3. **Verify.** A fresh install says `ready: Vella running (pid N), no model loaded`: nothing is downloaded or loaded until the user asks. If it ends with `degraded: …` instead, Vella is running but a model the user keeps loaded did not load (for example not enough free memory); the previous app is kept for rollback and the command exits non-zero. Pass the line to the user. Vella's icon is in the menu bar. There is no command-line interface or skill to install; Vella is used by voice through its shortcut.
4. **Report** in one or two lines: installed, the version, the `ready:` line. Tell the user to approve Microphone and Accessibility access when macOS asks, and that the first dictation offers **Get <model>** in the menu. Ask whether they want **Launch at Login** (menu → Launch at Login) and which model to keep loaded (menu → Models… → Load); do neither yourself.

Updating: `git pull && scripts/install.sh`. Models, recordings and settings are kept; an idle Vella is quit and restarted automatically, and the previous app is removed only after the new one reports ready. `scripts/install-release.sh <version> --dry-run` verifies a release without installing it.

Building from source instead: `VELLA_BUILD=source scripts/install.sh` (needs Command Line Tools, full Xcode and its Metal Toolchain; it prints the fixing command for anything missing).

Uninstall: quit Vella, delete `~/Applications/Vella.app` and, only if the user wants their models and recordings gone too, `~/Library/Application Support/Vella`.
