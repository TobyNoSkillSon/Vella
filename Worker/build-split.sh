#!/bin/bash
# Compatibility build: existing CLT Swift/C++ compiler + Xcode's Metal compiler.
# Installs nothing. This is needed on macOS 26.6 with Xcode 27 Swift 6.4.
set -euo pipefail
root=$(cd -- "$(dirname "$0")" && pwd)
clt=/Library/Developer/CommandLineTools
xcode=${VELLA_XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEVELOPER_DIR="$clt" "$clt/usr/bin/swift" build --package-path "$root" -c release --build-system native
source="$root/.build/checkouts/mlx-swift"
[[ $(git -C "$source" rev-parse HEAD) == 901941965d82e4a216d4d117231d847d194c563d ]]
bin=$(DEVELOPER_DIR="$clt" "$clt/usr/bin/swift" build --package-path "$root" -c release --build-system native --show-bin-path)
metal="$root/.build/split-metal"
mkdir -p "$metal"
sdk=$(DEVELOPER_DIR="$xcode" xcrun --show-sdk-path)
# Exactly the ten prepared .metal files compiled by the pinned Cmlx Xcode target.
objects=()
while IFS= read -r file; do
    name=$(basename "$file" .metal)
    output="$metal/$name.air"
    DEVELOPER_DIR="$xcode" xcrun metal -c -target air64-apple-macos14.0 -isysroot "$sdk" \
        -fmetal-math-mode=fast -fmetal-math-fp32-functions=fast "$file" -o "$output"
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
    otool -l "$bin/VellaWorker" | grep -A6 LC_BUILD_VERSION
    shasum -a 256 "$bin/VellaWorker" "$bundle/Contents/Resources/default.metallib" "$root/Package.resolved"
} > "$root/.build/split-build-provenance.txt"
printf '%s\n' "$bin/VellaWorker"
