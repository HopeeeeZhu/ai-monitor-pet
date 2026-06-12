#!/bin/bash
# 把 AI监工 搬到不受 macOS 隐私保护的位置 (~/Library/Application Support),
# 重建运行环境并重新打包 App。在终端跑: bash relocate.sh
set -e

SRC="/Users/hopeeee/Desktop/workspace/AI监工/pet-monitor"
DEST="$HOME/Library/Application Support/AIMonitorPet"
APP="$DEST/AI监工.app"

echo "==> 目标位置: $DEST"
mkdir -p "$DEST"

echo "==> 复制程序文件..."
cp "$SRC/monitor.py" "$DEST/"
rm -rf "$DEST/assets"
cp -R "$SRC/assets" "$DEST/assets"

echo "==> 创建运行环境并安装依赖 (约 1-2 分钟, 请耐心等)..."
rm -rf "$DEST/.venv"
python3 -m venv "$DEST/.venv"
"$DEST/.venv/bin/pip" install --quiet --upgrade pip
"$DEST/.venv/bin/pip" install --quiet pyobjc-framework-Cocoa pyobjc-framework-ApplicationServices Pillow

echo "==> 重新打包 App..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI监工</string>
  <key>CFBundleDisplayName</key><string>AI监工</string>
  <key>CFBundleIdentifier</key><string>com.hopeeee.aimonitor.pet</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>AIMonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/AIMonitor" <<LAUNCH
#!/bin/bash
DIR="$DEST"
cd "\$DIR" || exit 1
exec "\$DIR/.venv/bin/python" "\$DIR/monitor.py" >> "\$DIR/app.log" 2>&1
LAUNCH
chmod +x "$APP/Contents/MacOS/AIMonitor"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 生成图标..."
"$DEST/.venv/bin/python" - <<PY
from PIL import Image, ImageDraw
import os
DEST = "$DEST"
S = 1024
bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(bg)
d.rounded_rectangle([40, 40, S - 40, S - 40], radius=200, fill=(255, 238, 222, 255))
baby = Image.open(os.path.join(DEST, "assets/wave_0.png")).convert("RGBA")
th = int(S * 0.74); sc = th / baby.height; w = int(baby.width * sc)
baby = baby.resize((w, th), Image.LANCZOS)
bg.alpha_composite(baby, ((S - w) // 2, S - th - 90))
bg.save(os.path.join(DEST, "AI监工.app/Contents/Resources/AppIcon.icns"))
print("   图标 OK")
PY

echo ""
echo "✅ 完成! 新 App 在: $APP"
echo "   Finder 会自动打开这个文件夹, 双击里面的 AI监工.app 即可。"
open "$DEST"
