#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="APKInMacOS"
DISPLAY_NAME="APK in macOS"
BUNDLE_ID="dev.apkinmacos.shelf"
BUILD_CONFIG="${BUILD_CONFIG:-release}"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [[ "${SKIP_BRIDGE_BUILD:-0}" == "1" ]] && [[ -f "$ROOT_DIR/Resources/display-bridge.jar" ]]; then
  echo "[package_app] 1/4 Reusing prebuilt Resources/display-bridge.jar..."
elif [[ -f "$ROOT_DIR/Resources/display-bridge.jar" ]] && [[ ! -f "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platforms/android-35/android.jar" ]]; then
  echo "[package_app] 1/4 Reusing prebuilt Resources/display-bridge.jar (Android SDK not present)..."
else
  echo "[package_app] 1/4 Building Android display-bridge.jar..."
  "$ROOT_DIR/script/build_bridge.sh"
fi

echo "[package_app] 2/4 Compiling macOS app ($BUILD_CONFIG)..."
(cd "$ROOT_DIR" && swift build -c "$BUILD_CONFIG" --product "$APP_NAME")
BUILD_BIN="$(cd "$ROOT_DIR" && swift build -c "$BUILD_CONFIG" --show-bin-path)/$APP_NAME"

echo "[package_app] 3/4 Assembling warm-ivory $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BIN" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Resources/display-bridge.jar" "$APP_RESOURCES/display-bridge.jar"

# Generate warm-ivory minimalist AppIcon.icns
ICON_TMP="$ROOT_DIR/.build/app-icon"
ICONSET="$ICON_TMP/AppIcon.iconset"
rm -rf "$ICON_TMP"
mkdir -p "$ICONSET"

python3 - "$ICON_TMP/base.png" <<'PY'
import sys, struct, zlib, math

out_png = sys.argv[1]
w = h = 1024
cx, cy = w / 2.0, h / 2.0
rows = []
for y in range(h):
    row = bytearray([0])
    for x in range(w):
        dx = max(abs(x - cx) - 310, 0)
        dy = max(abs(y - cy) - 310, 0)
        dist = math.hypot(dx, dy)
        if dist > 120:
            row.extend([0, 0, 0, 0])
            continue

        # Subtle warm cream-ivory gradient background (#FCF9F2 -> #F2EBDC)
        t = y / float(h)
        r = int(252 - 12 * t)
        g = int(249 - 16 * t)
        b = int(242 - 24 * t)

        # Delicate warm hairline inner ring
        if 112 < dist <= 120:
            r, g, b = 224, 214, 196

        # Minimalist layered warm-terracotta & warm-espresso Android robot head emblem
        # Back warm terracotta-sienna rounded square (#C46D48, matching EXEInMacOS)
        bx, by = 568, 444
        bdx = max(abs(x - bx) - 145, 0)
        bdy = max(abs(y - by) - 145, 0)
        if math.hypot(bdx, bdy) <= 44:
            r, g, b = 196, 109, 72

        # Front warm-espresso rounded square (#2C2722, matching EXEInMacOS)
        fx, fy = 456, 560
        fdx = max(abs(x - fx) - 155, 0)
        fdy = max(abs(y - fy) - 155, 0)
        if math.hypot(fdx, fdy) <= 46:
            r, g, b = 44, 39, 34

            # Centered minimalist Android robot head (dome + antennae, with terracotta eyes)
            # Dome baseline at (fx, fy + 48) so overall head+antennae centers cleanly in the card.
            rx = x - fx
            ry = y - (fy + 48)

            def dist_seg(px, py, x1, y1, x2, y2):
                vx, vy = x2 - x1, y2 - y1
                l2 = vx * vx + vy * vy
                if l2 == 0:
                    return math.hypot(px - x1, py - y1)
                t = max(0.0, min(1.0, ((px - x1) * vx + (py - y1) * vy) / l2))
                return math.hypot(px - (x1 + t * vx), py - (y1 + t * vy))

            in_antenna = (
                dist_seg(rx, ry, -36.0, -64.0, -62.0, -108.0) <= 8.5
                or dist_seg(rx, ry, 36.0, -64.0, 62.0, -108.0) <= 8.5
            )

            # Semicircle dome (R=84) with flat bottom & tangent rounded bottom corners (cr=10)
            in_dome = False
            if ry <= 0.0 and math.hypot(rx, ry) <= 84.0:
                if abs(rx) > 73.3212 and ry > -10.0:
                    in_dome = math.hypot(abs(rx) - 73.3212, ry + 10.0) <= 10.0
                else:
                    in_dome = True

            if in_antenna or in_dome:
                in_eye = (
                    math.hypot(rx + 34.0, ry + 36.0) <= 12.5
                    or math.hypot(rx - 34.0, ry + 36.0) <= 12.5
                )
                if in_eye:
                    r, g, b = 196, 109, 72
                else:
                    r, g, b = 250, 247, 240

        row.extend([max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)), 255])
    rows.append(bytes(row))

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

raw = b"".join(rows)
ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
with open(out_png, "wb") as f:
    f.write(png)
PY

for pair in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" "64:icon_32x32@2x.png" \
            "128:icon_128x128.png" "256:icon_128x128@2x.png" "256:icon_256x256.png" "512:icon_256x256@2x.png" \
            "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
  sz="${pair%%:*}"
  fn="${pair#*:}"
  /usr/bin/sips -z "$sz" "$sz" "$ICON_TMP/base.png" --out "$ICONSET/$fn" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>en</string>
  </array>
  <key>CFBundleAllowMixedLocalizations</key>
  <true/>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>apk</string>
        <string>xapk</string>
        <string>apkm</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Android Application Package</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.android.package-archive</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.zip-archive</string>
        <string>public.data</string>
      </array>
      <key>UTTypeDescription</key>
      <string>Android Application Package (APK)</string>
      <key>UTTypeIdentifier</key>
      <string>com.android.package-archive</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>apk</string>
        </array>
        <key>public.mime-type</key>
        <array>
          <string>application/vnd.android.package-archive</string>
        </array>
      </dict>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>APK in macOS Deep Link</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>apkinmacos</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "[package_app] 4/4 Signing & registering..."
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREG" ]]; then
  "$LSREG" -f "$APP_BUNDLE" || true
fi
echo "[package_app] Ready: $APP_BUNDLE"
