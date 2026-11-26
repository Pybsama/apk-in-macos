#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK_DIR="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_JAR="$SDK_DIR/platforms/android-35/android.jar"
BUILD_TOOLS="$SDK_DIR/build-tools/35.0.0"

if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
  :
elif [[ -x "/opt/homebrew/opt/openjdk@21/bin/javac" ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
elif [[ -x "/opt/homebrew/opt/openjdk/bin/javac" ]]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk"
else
  echo "Error: javac not found" >&2
  exit 1
fi
export PATH="$JAVA_HOME/bin:$PATH"

OUT_DIR="$ROOT_DIR/dist/test-apks"
WORK_DIR="$ROOT_DIR/.build/test-apks"
KEYSTORE="$WORK_DIR/debug.keystore"
mkdir -p "$OUT_DIR" "$WORK_DIR"

if [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair -v -keystore "$KEYSTORE" -storepass android \
    -alias debugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Local Test,O=Dev,C=US" >/dev/null 2>&1
fi

make_icon() {
  local out_png="$1" bg="$2" fg="$3" shape="$4"
  python3 - "$out_png" "$bg" "$fg" "$shape" <<'PY'
import sys, struct, zlib, math
out_png, bg, fg, shape = sys.argv[1:5]
w = h = 192
br, bgg, bb = int(bg[0:2], 16), int(bg[2:4], 16), int(bg[4:6], 16)
fr, fgg, fb = int(fg[0:2], 16), int(fg[2:4], 16), int(fg[4:6], 16)
cx = cy = w / 2.0
rows = []
for y in range(h):
    row = bytearray([0])
    for x in range(w):
        dx = max(abs(x - cx) - 56, 0)
        dy = max(abs(y - cy) - 56, 0)
        if math.hypot(dx, dy) > 36:
            row.extend([0, 0, 0, 0])
            continue
        r, g, b = br, bgg, bb
        if shape == "plus":
            if (abs(x - cx) < 11 and abs(y - cy) < 38) or (abs(y - cy) < 11 and abs(x - cx) < 38):
                r, g, b = fr, fgg, fb
        else:
            d = math.hypot(x - cx, y - cy)
            if 32 < d < 46 or d < 13:
                r, g, b = fr, fgg, fb
        row.extend([r, g, b, 255])
    rows.append(bytes(row))
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b"")
with open(out_png, "wb") as f: f.write(png)
PY
}

build_apk() {
  local name="$1" pkg_dir="$2" bg="$3" fg="$4" shape="$5"
  local src="$ROOT_DIR/TestApps/$name"
  local tmp="$WORK_DIR/$name"
  rm -rf "$tmp"
  mkdir -p "$tmp/res/mipmap-xxxhdpi" "$tmp/classes" "$tmp/dex" "$tmp/gen"

  make_icon "$tmp/res/mipmap-xxxhdpi/ic_launcher.png" "$bg" "$fg" "$shape"
  "$BUILD_TOOLS/aapt2" compile -o "$tmp/res.zip" "$tmp/res/mipmap-xxxhdpi/ic_launcher.png"
  "$BUILD_TOOLS/aapt2" link -I "$ANDROID_JAR" --manifest "$src/AndroidManifest.xml" --java "$tmp/gen" -o "$tmp/base.apk" "$tmp/res.zip"
  javac --release 11 -cp "$ANDROID_JAR" -d "$tmp/classes" "$src/src/$pkg_dir/"*.java "$tmp/gen/$pkg_dir/R.java"
  "$BUILD_TOOLS/d8" --min-api 28 --lib "$ANDROID_JAR" --output "$tmp/dex" $(find "$tmp/classes" -name '*.class')
  cp "$tmp/base.apk" "$tmp/unsigned.apk"
  (cd "$tmp/dex" && zip -q -u "$tmp/unsigned.apk" classes.dex)
  "$BUILD_TOOLS/zipalign" -f 4 "$tmp/unsigned.apk" "$tmp/aligned.apk"
  "$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android --out "$OUT_DIR/$name.apk" "$tmp/aligned.apk"
  echo "[build_test_apks] Built $OUT_DIR/$name.apk"
}

build_apk "CounterDemo" "dev/apkinmacos/counterdemo" "4E8C62" "FAF7F0" "plus"
build_apk "SketchNotes" "dev/apkinmacos/sketchnotes" "C28B3C" "FAF7F0" "ring"
