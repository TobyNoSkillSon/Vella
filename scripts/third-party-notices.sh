#!/usr/bin/env bash
# Write THIRD_PARTY_NOTICES.md: the licence of every package in Worker/Package.resolved and of the code MLX vendors,
# copied verbatim from the resolved checkouts, plus the code adapted into the helpers, the artwork and audio in the app
# and the licences of the catalog's models (Resources/models.json).
#
# Run after changing a dependency pin or the catalog, review the diff, commit. The checkouts come from
# `swift package resolve --package-path Worker` (or any Worker build); VELLA_CHECKOUTS points elsewhere.
# scripts/build.sh ships the file in Vella.app/Contents/Resources; Tests/VellaCoreTests/NoticesTests checks it.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECKOUTS="${VELLA_CHECKOUTS:-Worker/.build/checkouts}"
OUT=THIRD_PARTY_NOTICES.md
RESOLVED=Worker/Package.resolved
command -v jq >/dev/null || { echo 'jq is required (macOS 15 and later include it)' >&2; exit 1; }
fail() { echo "third-party-notices: $*" >&2; exit 1; }

# identity | component | what Vella uses it for | licence | files (path[:first-last], comma separated)
# A line range copies a licence header from a source file (1-based, inclusive).
INVENTORY='
mlx-swift|mlx-swift (MLX, MLXNN, MLXFast, MLXFFT)|Swift API for MLX: the model runtime of both helpers|MIT|LICENSE
mlx-swift|MLX (vendored in mlx-swift)|array library and Metal kernels (mlx.metallib)|MIT|Source/Cmlx/mlx/LICENSE
mlx-swift|mlx-c (vendored in mlx-swift)|C API between MLX and Swift|MIT|Source/Cmlx/mlx-c/LICENSE
mlx-swift|fmt (vendored in mlx-swift)|string formatting inside MLX|MIT|Source/Cmlx/fmt/LICENSE
mlx-swift|nlohmann/json (vendored in mlx-swift)|JSON inside MLX (safetensors headers)|MIT|Source/Cmlx/json/LICENSE.MIT
mlx-swift|metal-cpp (vendored in mlx-swift)|C++ Metal bindings inside MLX|Apache-2.0|Source/Cmlx/metal-cpp/LICENSE.txt
mlx-swift|pocketfft (vendored in MLX)|CPU FFT inside MLX (the audio front ends use MLXFFT)|BSD-3-Clause|Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h:1-35
mlx-swift|ThreadPool (adapted in MLX)|thread pool inside MLX|zlib|Source/Cmlx/mlx/mlx/threadpool.h:1-20
mlx-swift|NVIDIA CCCL complex math (adapted in MLX Metal kernels)|complex exponential kernel|Apache-2.0|Source/Cmlx/mlx/mlx/backend/metal/kernels/cexpf.h:1-18
mlx-swift|SmallVector from V8 (adapted in MLX)|small-vector container behind MLX array shapes and strides|BSD-3-Clause|Source/Cmlx/mlx/mlx/small_vector.h:1-28
mlx-swift|expm1f by Norbert Juffa (adapted in MLX Metal kernels)|expm1/erf Metal kernel source, compiled at run time|BSD-2-Clause|Source/Cmlx/mlx/mlx/backend/metal/kernels/expm1f.h:7-30
mlx-swift|nlohmann/json third-party parts (vendored in mlx-swift)|Grisu2 number formatting, UTF-8 decoding, Hedley macros and integer_sequence inside JSON|MIT (per the nlohmann/json SPDX headers; the Abseil code is Apache-2.0, text under metal-cpp above)|Source/Cmlx/json/include/nlohmann/detail/conversions/to_chars.hpp:1-8,Source/Cmlx/json/include/nlohmann/detail/conversions/to_chars.hpp:25-33,Source/Cmlx/json/include/nlohmann/detail/output/serializer.hpp:1-8,Source/Cmlx/json/include/nlohmann/detail/output/serializer.hpp:897-898,Source/Cmlx/json/include/nlohmann/thirdparty/hedley/hedley.hpp:3-14,Source/Cmlx/json/include/nlohmann/detail/meta/cpp_future.hpp:1-8,Source/Cmlx/json/include/nlohmann/detail/meta/cpp_future.hpp:40-41
swift-numerics|swift-numerics|real-number protocols used by mlx-swift|Apache-2.0 with Runtime Library Exception|LICENSE.txt
mlx-swift-lm|mlx-swift-lm (MLXLMCommon)|quantization configuration, key-value caches and attention helpers of the speech models|MIT|LICENSE
swift-transformers|swift-transformers (Tokenizers, Hub)|tokenizer.json loading for the Qwen3 ASR and Whisper tokenizers; its download code is never called|Apache-2.0|LICENSE
swift-jinja|swift-jinja|chat templates, linked by swift-transformers|Apache-2.0|LICENSE
yyjson|yyjson|JSON parsing, linked by swift-transformers|MIT|LICENSE
swift-collections|swift-collections (OrderedCollections)|ordered dictionaries, linked by swift-transformers|Apache-2.0 with Runtime Library Exception|LICENSE.txt
swift-crypto|swift-crypto|hashing, linked by swift-transformers (forwards to CryptoKit on macOS)|Apache-2.0|NOTICE.txt,LICENSE.txt
swift-asn1|swift-asn1|resolved dependency of swift-crypto|Apache-2.0|NOTICE.txt,LICENSE.txt
swift-syntax|swift-syntax|not in the app: resolved for the macro targets of mlx-swift-lm, which Vella does not build|Apache-2.0 with Runtime Library Exception|LICENSE.txt
'
# Code copied or adapted into Worker/Sources, with its licence file in Worker/.
ADAPTED='
mlx-audio-swift|https://github.com/Blaizzy/mlx-audio-swift at 01dec7c9bdce3088a6b6b7ab9f2e403458195efb|the speech models in Worker/Sources/MLXAudioSTT (Parakeet and NeMo layers, Nemotron, Qwen3 ASR, Whisper), generation and output types, audio and DSP utilities; changed for Vella (local loading only, optimized paths)|MIT|Worker/LICENSE-mlx-audio-swift
mlx-audio|https://github.com/Blaizzy/mlx-audio at v0.5.1|the mel filterbank of the Parakeet front end and the streaming DSP|MIT|Worker/LICENSE-mlx-audio-python
mlx-whisper|https://github.com/ml-explore/mlx-examples (whisper)|Whisper decoding settings|MIT|Worker/LICENSE-mlx-whisper
'
# Artwork in the app: name | source | what it is in Vella | licence | files (relative to the repository)
ARTWORK='
MLX logo|https://github.com/ml-explore/mlx/blob/9c3d35571ac450a8ecf5c17b4d0e3fac52c08bc8/docs/logo/mlx_logo_dark.svg|the Standard row icon of the Models table (Standard is the plain MLX runtime): `Resources/mlx-logo.pdf`, the glyph outlines of that SVG written as a template image by `scripts/mlx-logo.swift` (its white and 57 % grey fills become 100 % and 57 % opacity)|MIT|Resources/LICENSE-mlx
'
# Catalog family id → upstream weights (the repository the MLX conversions were made from).
UPSTREAM='
parakeet-v3-ultra|moondream/parakeet-ultra (post-trained from nvidia/parakeet-tdt-0.6b-v3)
parakeet-v3|nvidia/parakeet-tdt-0.6b-v3
qwen3-asr-1.7b|Qwen/Qwen3-ASR-1.7B
qwen3-asr-0.6b|Qwen/Qwen3-ASR-0.6B
nemotron-3.5-streaming-0.6b|nvidia/nemotron-3.5-asr-streaming-0.6b
whisper-large-v3|openai/whisper-large-v3
whisper-large-v3-turbo|openai/whisper-large-v3-turbo
'

pins="$(jq -r '.pins[] | [.identity, .location, (.state.version // "revision"), .state.revision] | join("|")' "$RESOLVED")"
pin() { awk -F'|' -v id="$1" '$1 == id' <<<"$pins"; }
while IFS='|' read -r identity _; do
  grep -q "^$identity|" <<<"$INVENTORY" || fail "$RESOLVED pins $identity, which has no inventory entry"
done <<<"$pins"
[[ -f "$CHECKOUTS/mlx-swift/LICENSE" ]] || fail "no checkouts in $CHECKOUTS; run: swift package resolve --package-path Worker"
for identity in $(awk -F'|' 'NF { print $1 }' <<<"$pins"); do
  expected="$(pin "$identity" | cut -d'|' -f4)"
  actual="$(git -C "$CHECKOUTS/$identity" rev-parse HEAD 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || fail "$CHECKOUTS/$identity is at ${actual:-nothing}, pinned $expected; run: swift package resolve --package-path Worker"
done

# verbatim FILE [FIRST LAST]: a fenced copy (trailing whitespace dropped; content unchanged).
verbatim() {
  local text
  if [[ $# -eq 3 ]]; then
    text="$(sed -n "$2,$3p" "$1")"
    grep -qiE 'copyright|licen[cs]e' <<<"$text" || fail "$1 lines $2-$3 hold no copyright or licence text (a pin change moved the header: fix the range)"
  else
    text="$(cat "$1")"
  fi
  grep -q '^````' <<<"$text" && fail "$1 contains a Markdown fence"
  printf '````text\n%s\n````\n\n' "$text"
}
# files ROOT LIST: each file of a comma-separated list, with a heading.
files() {
  local root="$1" item rel range
  IFS=',' read -ra items <<<"$2"
  for item in "${items[@]}"; do
    rel="${item%%:*}"; range=""
    [[ "$item" == *:* ]] && range="${item#*:}"
    [[ -f "$root/$rel" ]] || fail "missing $root/$rel"
    if [[ -n "$range" ]]; then
      printf '`%s` (lines %s)\n\n' "$rel" "$range"
      verbatim "$root/$rel" "${range%-*}" "${range#*-}"
    else
      printf '`%s`\n\n' "$rel"
      verbatim "$root/$rel"
    fi
  done
}

{
  cat <<'EOF'
# Third-party notices

Vella 2.0's own code is licensed under the MIT License; published 0.x releases remain Apache-2.0. See LICENSE and NOTICE. Vella.app carries this file, LICENSE and NOTICE in `Contents/Resources`. The licences below cover what the app contains that others wrote; they are not replaced by Vella's licence.

This file is written by `scripts/third-party-notices.sh` from `Worker/Package.resolved`, the pinned checkouts and `Resources/models.json`. Each licence is reproduced verbatim from the pinned source.

1. [Swift packages in the recognition helpers](#swift-packages-in-the-recognition-helpers)
2. [Code adapted into the recognition helpers](#code-adapted-into-the-recognition-helpers)
3. [Artwork in the app](#artwork-in-the-app)
4. [Audio in the app](#audio-in-the-app)
5. [Model weights (downloaded, not included)](#model-weights-downloaded-not-included)
6. [Apple](#apple)

## Swift packages in the recognition helpers

The menu-bar app, the `vella` command and VellaInstallTool link no third-party packages. The recognition helpers (VellaWorker for Dictation, VellaStreamingWorker for Streaming) link the packages below, pinned in `Worker/Package.resolved`; `mlx.metallib` is compiled from MLX's Metal sources.

EOF
  while IFS='|' read -r identity component use licence list; do
    [[ -n "$identity" ]] || continue
    IFS='|' read -r _ location version revision <<<"$(pin "$identity")"
    [[ -n "$revision" ]] || fail "inventory names $identity, which $RESOLVED does not pin"
    printf '### %s\n\n' "$component"
    printf -- '- package: %s %s (%s)\n- source: %s\n- licence: %s\n- used for: %s\n\n' "$identity" "$version" "$revision" "$location" "$licence" "$use"
    files "$CHECKOUTS/$identity" "$list"
  done <<<"$INVENTORY"

  cat <<'EOF'
## Code adapted into the recognition helpers

This code was copied into `Worker/Sources` and changed there. Its licence files are in `Worker/`.

EOF
  while IFS='|' read -r name origin use licence list; do
    [[ -n "$name" ]] || continue
    printf '### %s\n\n- source: %s\n- licence: %s\n- used for: %s\n\n' "$name" "$origin" "$licence" "$use"
    files . "$list"
  done <<<"$ADAPTED"

  cat <<'EOF'
## Artwork in the app

MLX is Apple's machine-learning framework, which Vella's recognition helpers run on. Its logo marks the Models table's Standard row, the path that runs on plain MLX; no endorsement by Apple or the MLX project is implied.

EOF
  while IFS='|' read -r name origin use licence list; do
    [[ -n "$name" ]] || continue
    printf '### %s\n\n- source: %s\n- licence: %s\n- used for: %s\n\n' "$name" "$origin" "$licence" "$use"
    files . "$list"
  done <<<"$ARTWORK"

  cat <<'EOF'
## Audio in the app

- **Self-test clips.** `VellaWorker_VellaWorker.bundle` holds five LibriSpeech test-clean utterances (`5142-36377-0000`, `672-122797-0073`, `61-70968-0021`, `6930-75918-0000`, `121-127105-0022`), converted to 16 kHz mono PCM WAV. The optimized paths are checked against the stock MLX path on them when a model loads, and `vella diagnose` times them.
- **Calibration clip.** `Calibration/speech.wav` is LibriSpeech test-clean `260-123286-0000` (7.04 s), with its LibriSpeech-PC formatted text, decoded to 16 kHz mono PCM WAV without trimming or gain changes. It estimates transcription time.

LibriSpeech by Vassil Panayotov, Guoguo Chen, Daniel Povey and Sanjeev Khudanpur (https://www.openslr.org/12/), from LibriVox recordings. LibriSpeech-PC by A. Meister et al., NVIDIA (https://www.openslr.org/145/). Both under Creative Commons Attribution 4.0 International (https://creativecommons.org/licenses/by/4.0/); the full licence text and an `ATTRIBUTION.md` travel with each set of clips. No endorsement is implied.

## Model weights (downloaded, not included)

Vella.app contains no model weights. When you confirm a download, Vella fetches the pinned revision from Hugging Face, and the weights keep their own licence; the licence files in a model's repository are downloaded with it. Precisions without a published download are made on your Mac from the downloaded weights and are not redistributed. Each model's licence also shows in its table tooltip.

| Model | In the app | Licence | Upstream weights | MLX downloads (Hugging Face) |
|---|---|---|---|---|
EOF
  jq -r '.families[] | [.id, .name, (if .offered then "yes" else "no" end), .license,
      ([.variants | to_entries[] | select((.value.repository // "") != "") | "`\(.value.repository)`"] | unique | join(", "))] | join("|")' Resources/models.json |
  while IFS='|' read -r id name offered licence repositories; do
    upstream="$(awk -F'|' -v id="$id" '$1 == id { print $2 }' <<<"$UPSTREAM")"
    [[ -n "$upstream" ]] || fail "Resources/models.json family $id has no upstream entry in this script"
    printf '| %s | %s | %s | %s | %s |\n' "$name" "$offered" "$licence" "$upstream" "$repositories"
  done
  cat <<'EOF'

Licence names follow the upstream model cards: `cc-by-4.0` is Creative Commons Attribution 4.0, `apache-2.0` the Apache License 2.0, `mit` the MIT License. Nemotron 3.5's upstream card specifies the OpenMDW License 1.1 (https://openmdw.ai/license/1-1/); its MLX conversions still carry the NVIDIA Open Model License in their card metadata.

## Apple

macOS frameworks and SF Symbols are used under Apple's terms. The app icon is drawn by Vella's own `scripts/icon.swift`; it is not a redistributed SF Symbol image.
EOF
} | sed 's/[[:space:]]*$//' >"$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT ($(grep -c '^### ' "$OUT") components, $(awk -F'|' 'NF' <<<"$pins" | wc -l | tr -d ' ') pins)"
