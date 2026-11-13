#!/bin/zsh
# Compiles and runs the standalone lsof parser tests.
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)/lsof-parser-tests"
swiftc -O -parse-as-library \
  "$PROJECT_DIR/Sources/LsofParser.swift" \
  "$PROJECT_DIR/Tests/LsofParserTests.swift" \
  -o "$OUT"
"$OUT"
