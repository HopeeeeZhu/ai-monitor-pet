#!/bin/bash
# 启动宠物。加 --debug 看检测细节。
cd "$(dirname "$0")"
./.venv/bin/python monitor.py "$@"
