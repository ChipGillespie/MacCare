#!/bin/zsh
# Compiles and runs the standalone test suites.
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Running LsofParser Tests ==="
OUT1="$(mktemp -d)/lsof-parser-tests"
swiftc -O -parse-as-library \
  "$PROJECT_DIR/Sources/LsofParser.swift" \
  "$PROJECT_DIR/Tests/LsofParserTests.swift" \
  -o "$OUT1"
"$OUT1"

echo "\n=== Running TouchIDManager Tests ==="
OUT2="$(mktemp -d)/touchid-tests"
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
  "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Sources/TouchIDManager.swift" \
  "$PROJECT_DIR/Sources/SystemScanner.swift" \
  "$PROJECT_DIR/Tests/TouchIDManagerTests.swift" \
  -o "$OUT2"
"$OUT2"
