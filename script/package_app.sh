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

        # Minimalist layered sage-green & warm-espresso Android robot emblem
        # Back muted botanical sage green rounded tile (#4E825E)
        bx, by = 568, 444
        bdx = max(abs(x - bx) - 135, 0)
        bdy = max(abs(y - by) - 155, 0)
        if math.hypot(bdx, bdy) <= 44:
            r, g, b = 78, 130, 94

        # Front warm-espresso rounded app window (#2C2722)
        fx, fy = 456, 560
        fdx = max(abs(x - fx) - 145, 0)
        fdy = max(abs(y - fy) - 165, 0)
        if math.hypot(fdx, fdy) <= 46:
            r, g, b = 44, 39, 34

            # Normalized 0..100 Android robot silhouette inside front window
            scale = 2.18
            nx = (x - fx) / scale + 50.0
            ny = (y - fy) / scale + 50.0

            def dist_seg(px, py, x1, y1, x2, y2):
                vx, vy = x2 - x1, y2 - y1
                l2 = vx * vx + vy * vy
                if l2 == 0:
                    return math.hypot(px - x1, py - y1)
                t = max(0.0, min(1.0, ((px - x1) * vx + (py - y1) * vy) / l2))
                return math.hypot(px - (x1 + t * vx), py - (y1 + t * vy))

            def in_capsule(px, py, x1, y1, x2, y2, rad):
                return dist_seg(px, py, x1, y1, x2, y2) <= rad

            in_robot = False
            # Antennae
            if in_capsule(nx, ny, 39.0, 20.0, 31.0, 9.0, 2.3) or in_capsule(nx, ny, 61.0, 20.0, 69.0, 9.0, 2.3):
                in_robot = True
            # Semicircle head dome (center 50, 38, radius 21.5)
            elif ny <= 38.0 and math.hypot(nx - 50.0, ny - 38.0) <= 21.5:
                in_robot = True
            # Torso (x: 28.5..71.5, y: 41..76, rounded bottom corners r=7, top r=2)
            elif 28.5 <= nx <= 71.5 and 41.0 <= ny <= 76.0:
                in_top = True
                if ny < 43.0 and nx < 30.5:
                    in_top = math.hypot(nx - 30.5, ny - 43.0) <= 2.0
                elif ny < 43.0 and nx > 69.5:
                    in_top = math.hypot(nx - 69.5, ny - 43.0) <= 2.0
                in_bot = True
                if ny > 69.0 and nx < 35.5:
                    in_bot = math.hypot(nx - 35.5, ny - 69.0) <= 7.0
                elif ny > 69.0 and nx > 64.5:
                    in_bot = math.hypot(nx - 64.5, ny - 69.0) <= 7.0
                in_robot = in_top and in_bot
            # Arms
            elif in_capsule(nx, ny, 20.75, 45.75, 20.75, 62.25, 4.25) or in_capsule(nx, ny, 79.25, 45.75, 79.25, 62.25, 4.25):
                in_robot = True
            # Legs
            elif in_capsule(nx, ny, 42.0, 75.5, 42.0, 84.5, 4.5) or in_capsule(nx, ny, 58.0, 75.5, 58.0, 84.5, 4.5):
                in_robot = True

            if in_robot:
                in_eye = (math.hypot(nx - 41.2, ny - 28.5) <= 2.6) or (math.hypot(nx - 58.8, ny - 28.5) <= 2.6)
                if not in_eye:
                    # Crisp cream-ivory silhouette (#FAF7F0)
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
