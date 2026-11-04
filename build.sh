#!/bin/sh
# ./build.sh        build MiBuds.app
# ./build.sh test   run the protocol self-test
set -e
cd "$(dirname "$0")"
mkdir -p build

if [ "$1" = test ]; then
    swiftc -Onone -o build/selftest Sources/Protocol.swift Tests/main.swift
    exec build/selftest
fi

APP=build/MiBuds.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -target $arch-apple-macos13 -o build/MiBuds-$arch Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/MiBuds" build/MiBuds-arm64 build/MiBuds-x86_64
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" build/MiBuds.zip
echo "Built $APP and build/MiBuds.zip"
