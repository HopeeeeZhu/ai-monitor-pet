#!/bin/bash
# 一次性安装依赖 (在 pet-monitor 目录下运行)
set -e
cd "$(dirname "$0")"
python3 -m venv .venv
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install pyobjc-framework-Cocoa pyobjc-framework-ApplicationServices Pillow
echo ""
echo "✅ 安装完成。下一步:"
echo "   1) 放一张头像图片到 pet-monitor/pet.png (正方形最好)"
echo "   2) ./run.sh  启动宠物"
echo "   3) 首次运行去 系统设置 > 隐私与安全性 > 辅助功能 把'终端'勾上"
