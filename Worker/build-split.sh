#!/bin/bash
# Compatibility build: existing CLT Swift/C++ compiler + Xcode's Metal compiler.
# Installs nothing. Releases use Swift 6.3.3; Swift 6.4 builds get the weak swift_initBorrow link below.
set -euo pipefail
root=$(cd -- "$(dirname "$0")" && pwd)
clt=/Library/Developer/CommandLineTools
xcode=${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
link=()
swift_version=$(DEVELOPER_DIR="$clt" "$clt/usr/bin/swift" --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
read -r swift_major swift_minor <<<"$swift_version" || true
[[ "${swift_major:-}" =~ ^[0-9]+$ && "${swift_minor:-}" =~ ^[0-9]+$ ]] || { echo 'Could not read the Command Line Tools Swift version.' >&2; exit 1; }
# Swift 6.4 builds swift-collections' Optional._borrow() (SwiftStdlib 6.4, never called) with a strong reference to
# swift_initBorrow, which the macOS 26 runtime lacks, so dyld would refuse to launch the worker there. One weak
# declaration plus weak mismatch resolution makes that reference weak. Swift 6.3 compiles none of that code: no change.
# Mismatch resolution is link-wide: with Swift 6.4 it also weakens NSCocoaErrorDomain and NSLocalizedDescriptionKey,
# which macOS 26 exports, so they still bind. scripts/build.sh rejects any strong borrow reference that remains.
if (( swift_major > 6 || (swift_major == 6 && swift_minor >= 4) )); then
    shim="$root/.build/weak-swift-borrow.o"
    mkdir -p "$root/.build"
    printf '%s\n' 'extern void swift_initBorrow(void) __attribute__((weak_import));' \
        '__attribute__((used)) void *const vella_weak_swift_initBorrow = (void *)&swift_initBorrow;' |
        DEVELOPER_DIR="$clt" "$clt/usr/bin/clang" -target arm64-apple-macos26.0 -x c -c - -o "$shim"
    link=(-Xlinker "$shim" -Xlinker -weak_reference_mismatches -Xlinker weak)
fi
DEVELOPER_DIR="$clt" "$clt/usr/bin/swift" build --package-path "$root" -c release --build-system native ${link[@]+"${link[@]}"}
source="$root/.build/checkouts/mlx-swift"
[[ $(git -C "$source" rev-parse HEAD) == 901941965d82e4a216d4d117231d847d194c563d ]]
bin=$(DEVELOPER_DIR="$clt" "$clt/usr/bin/swift" build --package-path "$root" -c release --build-system native --show-bin-path)
# Preserve the historical invocation path without shipping a second image.
ln -sfn VellaWorker "$bin/VellaStreamingWorker"
metal="$root/.build/split-metal"
mkdir -p "$metal" && : > "$metal/compile.log"
sdk=$(DEVELOPER_DIR="$xcode" xcrun --show-sdk-path)
# Exactly the ten prepared .metal files compiled by the pinned Cmlx Xcode target.
# Upstream MLX's kernel flags (CMake and Cmlx.xcconfig): no fast math, precise fp32 functions.
# Family pin (MTL_FAST_MATH=NO); changing it changes numerics and requalifies every model.
metal_flags=(-Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions)
objects=()
while IFS= read -r file; do
    name=$(basename "$file" .metal)
    output="$metal/$name.air"
    DEVELOPER_DIR="$xcode" xcrun metal -c -target air64-apple-macos14.0 -isysroot "$sdk" \
        "${metal_flags[@]}" "$file" -o "$output" 2>>"$metal/compile.log" || { tail -20 "$metal/compile.log" >&2; exit 1; }
    objects+=("$output")
done < <(find "$source/Source/Cmlx/mlx-generated/metal" -name '*.metal' | sort)
[[ ${#objects[@]} == 10 ]]
bundle="$bin/mlx-swift_Cmlx.bundle"
mkdir -p "$bundle/Contents/Resources"
DEVELOPER_DIR="$xcode" xcrun metallib "${objects[@]}" -o "$bundle/Contents/Resources/default.metallib"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.vella.mlx-swift-Cmlx</string>
<key>CFBundleName</key><string>mlx-swift_Cmlx</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
{
    echo 'Swift and C++: existing Command Line Tools'
    DEVELOPER_DIR="$clt" "$clt/usr/bin/swift" --version
    DEVELOPER_DIR="$clt" "$clt/usr/bin/clang" --version
    echo 'Shaders: Xcode Metal Toolchain (no Xcode-built Swift artifact used)'
    DEVELOPER_DIR="$xcode" xcrun metal --version
    echo "Metal flags: ${metal_flags[*]}"
    otool -l "$bin/VellaWorker" | grep -A6 LC_BUILD_VERSION
    shasum -a 256 "$bin/VellaWorker" "$bundle/Contents/Resources/default.metallib" "$root/Package.resolved"
} > "$root/.build/split-build-provenance.txt"
printf '%s\n' "$bin/VellaWorker"
