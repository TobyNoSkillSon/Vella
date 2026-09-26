# Installing Vella (for coding agents)

Your user asked you to install Vella: a menu-bar app for offline dictation and live transcription on their Mac. Do this, then tell them what you did.

1. **Check.** Apple Silicon Mac, macOS 14 or newer. The prebuilt app needs nothing else. If a check fails, the installer prints the problem; pass it to the user and stop.
2. **Install.** From this repository: `scripts/install.sh`. It downloads the prebuilt app for this version with curl, verifies its SHA-256 and signature, puts it in `~/Applications`, starts it and waits until it is ready. It prints a few short lines and ends with `ready: …`. Never download the zip through a browser. If it says Vella is recording, transcribing or loading, wait a minute and run it again; it changed nothing.
3. **Install the skill** into your own harness: `vella skill --install <your skills directory>` writes `transcribe/SKILL.md` (when to transcribe audio files with Vella and how). The installer linked `vella` into `~/.local/bin`; if that is not on `PATH`, call `~/.local/bin/vella`.
4. **Verify.** A fresh install says `ready: Vella running (pid N), no model loaded`: nothing is downloaded or loaded until the user asks. If it ends with `degraded: …` instead, Vella is running but a model the user keeps loaded did not load (for example not enough free memory); the previous app is kept for rollback and the command exits non-zero. Pass the line to the user. Then run `vella status`: one line ending with the API address (`API http://127.0.0.1:<port>/v1`). Do not transcribe a test file yet: a fresh install has no model, and the API never downloads one.
5. **Report** in one or two lines: installed, the version, the `ready:` line, and that the `transcribe` skill is installed. Tell the user to approve Microphone and Accessibility access when macOS asks, and that the first dictation offers **Get <model>** in the menu. Ask whether they want **Launch at Login** (menu → Launch at Login) and which model to keep loaded (menu → Models… → Load); do neither yourself.

Updating: `git pull && scripts/install.sh`. Models, recordings and settings are kept; an idle Vella is quit and restarted automatically, and the previous app is removed only after the new one reports ready. `scripts/install-release.sh <version> --dry-run` verifies a release without installing it.

Building from source instead: `VELLA_BUILD=source scripts/install.sh` (needs Command Line Tools, full Xcode and its Metal Toolchain; it prints the fixing command for anything missing).

Problems: run `vella diagnose` and give the user its output and the issue link on its last line (a prefilled GitHub bug report; they decide whether to file it). It never starts Vella and loads nothing; `--load` loads the dictation model first, `--json` gives the data as JSON.

Uninstall: quit Vella, delete `~/Applications/Vella.app` and `~/.local/bin/vella`, and, only if the user wants their models and recordings gone too, `~/Library/Application Support/Vella`.
