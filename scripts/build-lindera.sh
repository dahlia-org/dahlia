#!/bin/zsh
set -euo pipefail

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
SOURCE_DIRECTORY="$REPOSITORY_ROOT/Vendor/DahliaLinderaSources"
DICTIONARIES_DIRECTORY="$SOURCE_DIRECTORY/Dictionaries"
IPADIC_ARCHIVE="$DICTIONARIES_DIRECTORY/2.3.4/mecab-ipadic-2.7.0-20250920.tar.gz"
IPADIC_SHA256="a7ba9f645ffe7094e56ae1c4a81d100df8fbb1e28bbe1792622e9728e162db3d"
OUTPUT_PATH="$REPOSITORY_ROOT/Vendor/DahliaLindera.xcframework"
TEMPORARY_DIRECTORY=$(mktemp -d)
DICTIONARY_CACHE="$TEMPORARY_DIRECTORY/dictionaries"
TARGET_DIRECTORY="$TEMPORARY_DIRECTORY/cargo-target/aarch64-apple-darwin/release"
LIBRARY_PATH="$TARGET_DIRECTORY/libDahliaLindera.a"

function cleanup {
    rm -rf "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

if [[ ! -f "$IPADIC_ARCHIVE" ]]; then
    echo "error: vendored IPADIC archive is missing" >&2
    exit 1
fi
ACTUAL_IPADIC_SHA256=$(shasum -a 256 "$IPADIC_ARCHIVE" | awk '{print $1}')
if [[ "$ACTUAL_IPADIC_SHA256" != "$IPADIC_SHA256" ]]; then
    echo "error: vendored IPADIC archive checksum mismatch" >&2
    exit 1
fi
mkdir -p "$DICTIONARY_CACHE/2.3.4"
cp "$IPADIC_ARCHIVE" "$DICTIONARY_CACHE/2.3.4/"
export LINDERA_DICTIONARIES_PATH="$DICTIONARY_CACHE"
export CARGO_TARGET_DIR="$TEMPORARY_DIRECTORY/cargo-target"

cd "$SOURCE_DIRECTORY"
cargo build --locked --release --target aarch64-apple-darwin
lipo -info "$LIBRARY_PATH" | grep -q "arm64"
nm -gU "$LIBRARY_PATH" > "$TEMPORARY_DIRECTORY/symbols.txt" 2>/dev/null || true
grep -q "_dahlia_lindera_tokenize" "$TEMPORARY_DIRECTORY/symbols.txt"

xcodebuild -create-xcframework \
    -library "$LIBRARY_PATH" \
    -headers "$SOURCE_DIRECTORY/include" \
    -output "$TEMPORARY_DIRECTORY/DahliaLindera.xcframework"

rm -rf "$OUTPUT_PATH"
mv "$TEMPORARY_DIRECTORY/DahliaLindera.xcframework" "$OUTPUT_PATH"
