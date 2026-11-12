#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

sdk_version="$(xcrun --show-sdk-version)"
swift build -c release --arch arm64 --arch x86_64 \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version"
binaries="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
version="$(plutil -extract CFBundleShortVersionString raw -o - Packaging/Info.plist)"
label=com.hostpin.app.local-writer
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.installer.XXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$staging"' EXIT
payload="$staging/payload"
app="$payload/Applications/HostPin.app"
helper="$payload/Library/PrivilegedHelperTools/$label"
daemon="$payload/Library/LaunchDaemons/$label.plist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$(dirname "$helper")" "$(dirname "$daemon")"
install -m 755 "$binaries/HostPin" "$app/Contents/MacOS/HostPin"
install -m 755 "$binaries/HostPinHelper" "$helper"
install -m 644 Packaging/Info.plist "$app/Contents/Info.plist"
install -m 644 Packaging/HostPin.icns "$app/Contents/Resources/"

cdhash() {
    local details hash
    details="$(codesign -d --verbose=4 --arch "$1" "$2" 2>&1)"
    hash="$(sed -n 's/^CDHash=//p' <<< "$details")"
    [[ "$hash" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s' "$hash"
}

codesign --force --options runtime --digest-algorithm sha256 --sign - --identifier "$label" "$helper"
helper_arm="$(cdhash arm64 "$helper")"
helper_intel="$(cdhash x86_64 "$helper")"
plutil -insert HostPinLocalWriterHashes -json "[\"$helper_arm\",\"$helper_intel\"]" "$app/Contents/Info.plist"
codesign --force --options runtime --digest-algorithm sha256 --sign - "$app"
app_arm="$(cdhash arm64 "$app")"
app_intel="$(cdhash x86_64 "$app")"

cat > "$daemon" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/$label</string>
        <string>$app_arm</string>
        <string>$app_intel</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>$label</key>
        <true/>
    </dict>
</dict>
</plist>
EOF
chmod 644 "$daemon"
plutil -lint "$daemon"
codesign --verify --deep --strict --all-architectures -R="identifier \"com.hostpin.app\" and (cdhash H\"$app_arm\" or cdhash H\"$app_intel\")" "$app"
codesign --verify --strict --all-architectures -R="identifier \"$label\" and (cdhash H\"$helper_arm\" or cdhash H\"$helper_intel\")" "$helper"

pkgbuild --analyze --root "$payload" "$staging/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$staging/components.plist"
plutil -replace 0.BundleOverwriteAction -string upgrade "$staging/components.plist"
pkgbuild --root "$payload" --install-location / --ownership recommended \
    --component-plist "$staging/components.plist" --scripts Packaging/local-installer \
    --identifier com.hostpin.app.local-installer --version "$version" --min-os-version 14.0 "$staging/HostPin.pkg"
plutil -create xml1 "$staging/requirements.plist"
plutil -insert os -json '["14.0"]' "$staging/requirements.plist"
plutil -insert arch -json '["arm64","x86_64"]' "$staging/requirements.plist"
output="HostPin-$version-Local.pkg"
productbuild --product "$staging/requirements.plist" --package "$staging/HostPin.pkg" "$staging/$output"
mv "$staging/$output" "dist/$output"
printf 'Built %s/dist/%s\n' "$PWD" "$output"
