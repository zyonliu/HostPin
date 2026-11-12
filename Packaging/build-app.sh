#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${HOSTPIN_SIGN_IDENTITY:--}"
configuration="${HOSTPIN_BUILD_CONFIGURATION:-release}"
case "$configuration" in
    debug|release) ;;
    *) printf '%s\n' 'HOSTPIN_BUILD_CONFIGURATION must be debug or release.' >&2; exit 1 ;;
esac

sdk_version="$(xcrun --show-sdk-version)"
swift build -c "$configuration" \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version"
binaries="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.hostpin.XXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$staging"' EXIT
app="$staging/HostPin.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp Packaging/Info.plist "$contents/Info.plist"
cp Packaging/HostPin.icns "$contents/Resources/"
cp "$binaries/HostPin" "$contents/MacOS/HostPin"

if [[ "$identity" == '-' ]]; then
    # An ad-hoc preview omits the system service.
    codesign --force --sign - "$app"
else
    mkdir -p "$contents/Library/LaunchDaemons"
    cp Packaging/com.hostpin.app.writer.plist "$contents/Library/LaunchDaemons/"
    cp "$binaries/HostPinHelper" "$contents/MacOS/HostPinHelper"
    codesign --force --options runtime --sign "$identity" --identifier com.hostpin.app.writer "$contents/MacOS/HostPinHelper"
    signature="$(codesign -d --verbose=4 "$contents/MacOS/HostPinHelper" 2>&1)"
    team="$(sed -n 's/^TeamIdentifier=//p' <<< "$signature")"
    if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
        printf '%s\n' 'Use an Apple-issued signing identity with a Team Identifier.' >&2
        exit 1
    fi
    requirement="anchor apple generic and identifier \"com.hostpin.app.writer\" and certificate leaf[subject.OU] = \"$team\""
    codesign -v -R="$requirement" "$contents/MacOS/HostPinHelper"
    plutil -insert HostPinTeamID -string "$team" "$contents/Info.plist"
    codesign --force --options runtime --sign "$identity" "$app"
    requirement="anchor apple generic and identifier \"com.hostpin.app\" and certificate leaf[subject.OU] = \"$team\""
    codesign -v -R="$requirement" "$app"
fi

codesign --verify --deep --strict "$app"
if [[ -e dist/HostPin.app ]]; then
    mv dist/HostPin.app "$staging/previous.app"
fi
if ! mv "$app" dist/HostPin.app; then
    if [[ -e "$staging/previous.app" ]]; then mv "$staging/previous.app" dist/HostPin.app; fi
    exit 1
fi
printf 'Built %s/dist/HostPin.app\n' "$PWD"
