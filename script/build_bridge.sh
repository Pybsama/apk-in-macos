#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK_DIR="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_JAR="$SDK_DIR/platforms/android-35/android.jar"
D8_BIN="$SDK_DIR/build-tools/35.0.0/d8"

if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
  JAVAC="$JAVA_HOME/bin/javac"
elif [[ -x "/opt/homebrew/opt/openjdk@21/bin/javac" ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
  JAVAC="$JAVA_HOME/bin/javac"
elif [[ -x "/opt/homebrew/opt/openjdk/bin/javac" ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk"
  JAVAC="$JAVA_HOME/bin/javac"
else
  echo "Error: javac not found" >&2
  exit 1
fi
export PATH="$JAVA_HOME/bin:$PATH"

BUILD_DIR="$ROOT_DIR/.build/android-bridge"
CLASSES_DIR="$BUILD_DIR/classes"
OUT_JAR="$ROOT_DIR/Resources/display-bridge.jar"

rm -rf "$BUILD_DIR"
mkdir -p "$CLASSES_DIR" "$(dirname "$OUT_JAR")"

"$JAVAC" --release 11 -cp "$ANDROID_JAR" -d "$CLASSES_DIR" \
  "$ROOT_DIR"/AndroidBridge/src/dev/apkinmacos/bridge/*.java

"$D8_BIN" --min-api 31 --lib "$ANDROID_JAR" --output "$OUT_JAR" \
  "$CLASSES_DIR"/dev/apkinmacos/bridge/*.class

echo "[build_bridge] Built $OUT_JAR ($(du -h "$OUT_JAR" | awk '{print $1}'))"
