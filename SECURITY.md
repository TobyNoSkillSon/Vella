# Security policy

## Reporting a vulnerability

Report it privately through GitHub: https://github.com/TobyNoSkillSon/Vella/security/advisories/new (the repository's **Security** tab → **Report a vulnerability**). Please do not open a public issue, discussion or pull request for it.

Include the Vella version (`vella status` prints it), your macOS version and chip, and the smallest request or steps that show the problem. The conversation stays in the private advisory. A fix ships in a new release, and the advisory is then published with credit to you unless you ask otherwise.

Only the latest release receives security fixes.

## What Vella exposes

Vella records the microphone only while you dictate, and keeps recordings and transcripts in `~/Library/Application Support/Vella`. The recognition helpers that run the models are separate processes in a sandbox that denies all network access.

The app serves an OpenAI-compatible HTTP API on the IPv4 loopback address (`127.0.0.1`) at a port chosen at launch. It has no authentication for uploads, by design: any process running as any user on the Mac can send it audio, and nothing off the Mac can reach it. It refuses what a web page could send. A request with an `Origin` header, a `Host` other than `127.0.0.1:<port>` or `localhost:<port>`, or a POST body that is neither `multipart/form-data` nor JSON is rejected before its body is read. A JSON request that names a local file to transcribe also needs a token that only processes able to read Vella's support directory can see. [docs/USAGE.md](docs/USAGE.md#transcribe-files-command-line-and-api) describes these checks.

Its network traffic is the release download at install time, model weights from Hugging Face when you confirm a download, a daily update check (one request to the GitHub releases API) and the release download when you update. There is no telemetry, and audio and transcripts never leave the Mac.

## In scope

- A way for a web page, another machine or anything else outside the Mac to reach or drive the API: bypassing the `Origin`, `Host` or `Content-Type` checks, DNS rebinding, or the API listening beyond loopback.
- A request that reads, writes or deletes files it should not: a local file transcribed without the token, or anything outside Vella's support directory written or deleted (for example through a crafted model name, path or upload).
- Audio, transcripts or the API token written where other users of the Mac can read them.
- A recognition helper reaching the network, or escaping its sandbox, including through a crafted model folder.
- Memory corruption or a crash of the app or a helper caused by the contents of a request or an audio file.
- Weaknesses in the installer, the updater or the release: installing an app whose SHA-256, code signature or build attestation does not match, or running downloaded code before it is verified.

## Out of scope

- Other processes on the same Mac uploading audio to the API. That is how it is meant to work (see above), including a local process using it heavily.
- Transcripts that are wrong, or text a model invents. Accuracy is model-dependent; the README reports each model's measured error rate.
- Apps you dictate into, clipboard managers and Universal Clipboard seeing the text Vella inserts or copies. That is how inserting text works.
- Forwarding the port to other machines yourself.
- Gatekeeper warnings about the ad-hoc signature when the zip is downloaded through a browser. The installer downloads it with curl instead.
- Vulnerabilities in dependencies (MLX, swift-transformers and others) or in model weights with no Vella-specific impact. Please report those upstream; tell us if Vella needs to update.

Model and settings mutations require the per-launch `X-Vella-Token` readable only from the local worker-status.json. OpenAI-style API keys remain ignored for transcription; they do not grant model-management authority. Get additionally requires explicit JSON `yes: true` (CLI `--yes`); model Select/Load/Reload/Unload and Keep Hot/Memory use the same controller/runtime as the app.

Delete additionally requires a catalog model id, the named dtype and explicit `yes: true`. It uses the same protected-path/selection/recording/in-use gate and ordered unload → Trash → registry update as the table; API clients cannot supply a filesystem path. Failed deletion keeps or restores the weights and manual residency.
