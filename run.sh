#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build --product CIMCKVM
binary_dir=$(swift build --show-bin-path)
bundle="$binary_dir/cimc-kvm.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources"
install -m 644 Assets/AppIcon.icns "$bundle/Resources/AppIcon.icns"
install -m 755 "$binary_dir/CIMCKVM" "$bundle/MacOS/CIMCKVM"
install -m 644 Assets/Info.plist "$bundle/Info.plist"
exec "$bundle/MacOS/CIMCKVM" "$@"
