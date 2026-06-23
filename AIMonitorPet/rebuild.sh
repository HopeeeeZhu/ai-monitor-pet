#!/bin/bash
# 重新编译 AIMonitorPet 并替换进 .app, 重新签名后重启
set -e
cd "$(dirname "$0")"

echo "==> 1/4 编译 (release)…"
swift build -c release

echo "==> 2/4 替换 .app 里的可执行文件…"
cp ".build/release/AIMonitorPet" "dist/AI监工.app/Contents/MacOS/AI监工"

echo "==> 3/4 重新 ad-hoc 签名…"
codesign --force --deep --sign - "dist/AI监工.app"

echo "==> 4/4 退出旧实例并启动新版本…"
pkill -f "AI监工" 2>/dev/null || true
sleep 1
open "dist/AI监工.app"

echo "✅ 完成。"
