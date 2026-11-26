#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-release}"

BUILD_CONFIG="$BUILD_CONFIG" "$ROOT_DIR/script/package_app.sh"
BUILD_CONFIG="$BUILD_CONFIG" "$ROOT_DIR/script/package_exe_app.sh"
