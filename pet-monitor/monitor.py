#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AI 监工 — 桌面宠物 (轻量版 / Claude.app + Codex.app)

宠物状态:
  - idle      : 没有 AI 在干活 -> 宠物睡觉 (Zzz)
  - running   : Claude/Codex 正在跑任务 -> 宠物跑动
  - waiting   : 某个 app 需要授权 -> 头顶弹出气泡 + 系统通知

检测手段 (GUI app, 无法依赖 hook):
  - running   : 用进程 CPU 占用判断 (启发式, 阈值可调)
  - waiting   : 用 Accessibility 扫 app 窗口里的"授权/允许/拒绝"按钮
  这两个信号对 Electron 类 app 不保证完美; 用 --debug 看到底抓到了什么再调。

用法:
  python3 monitor.py            # 正常运行
  python3 monitor.py --debug    # 每次轮询打印检测细节, 用来调阈值/关键词
"""

import sys
import os
import json
import subprocess

from AppKit import *
from Foundation import *
import objc

from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    AXIsProcessTrusted,
)

# ----------------------------------------------------------------------------
# 配置 (按需修改)
# ----------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")             # 立绘帧动画素材
POS_FILE = os.path.join(HERE, ".pet_pos.json")    # 记忆窗口位置

# 每个状态对应: 帧文件前缀(assets/<prefix>_N.png) + 播放速度(帧/秒) + 显示高度(px)
STATE_ANIM = {
    "idle":    {"prefix": "sleep", "fps": 2.5, "height": 95},
    "running": {"prefix": "run",   "fps": 8.0, "height": 128},
    "waiting": {"prefix": "wave",  "fps": 5.0, "height": 128},
}

# 要监测的 app。match = 进程命令行里出现的子串 (区分大小写)。
APPS = [
    {"key": "claude", "display": "Claude", "match": "Claude.app", "cpu_threshold": 15.0},
    {"key": "codex",  "display": "Codex",  "match": "Codex.app",  "cpu_threshold": 15.0},
]

# 滞回: 判定在跑后, 即使 CPU 短暂掉下去, 也保持"在跑"这么多次轮询(防抖)
RUNNING_HOLD = 3

# "需要授权" 按钮标题关键词 (命中任意一个即判定 waiting)。保守集合, 减少误报。
APPROVAL_BTN_KEYWORDS = [
    "allow", "approve", "accept", "deny", "reject", "authorize", "always allow",
    "允许", "同意", "批准", "拒绝", "授权",
]

POLL_INTERVAL = 1.5      # 检测间隔(秒)
ANIM_INTERVAL = 0.08     # 动画刷新间隔(秒)

DEBUG = "--debug" in sys.argv
DEMO = "--demo" in sys.argv   # 演示模式: 每3秒循环切 睡觉/走路/举手, 用来预览动画(不做真实检测)

# ----------------------------------------------------------------------------
# 检测引擎
# ----------------------------------------------------------------------------
def _ax_attr(el, attr):
    err, val = AXUIElementCopyAttributeValue(el, attr, None)
    return val if err == 0 else None


def ax_approval_buttons(pid):
    """扫 app 的窗口树, 返回命中授权关键词的按钮标题列表 (best-effort)。"""
    found = []
    visited = [0]
    app = AXUIElementCreateApplication(pid)

    def walk(el, depth):
        if depth > 8 or visited[0] > 500:
            return
        visited[0] += 1
        role = _ax_attr(el, "AXRole") or ""
        title = _ax_attr(el, "AXTitle") or ""
        if role == "AXButton" and title:
            t = title.lower()
            for kw in APPROVAL_BTN_KEYWORDS:
                if kw in t:
                    found.append(title)
                    break
        for child in (_ax_attr(el, "AXChildren") or []):
            walk(child, depth + 1)

    for win in (_ax_attr(app, "AXWindows") or []):
        walk(win, 0)
    return found


def sample_processes():
    """一次 ps 扫所有进程, 汇总每个目标 app 的 运行/CPU/主进程pid。"""
    info = {a["key"]: {"running": False, "cpu": 0.0, "main_pid": None} for a in APPS}
    try:
        out = subprocess.run(
            ["ps", "-axo", "pid=,%cpu=,command="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return info
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        pid_s, cpu_s, cmd = parts
        for a in APPS:
            if a["match"] in cmd:
                d = info[a["key"]]
                d["running"] = True
                try:
                    d["cpu"] += float(cpu_s)
                except ValueError:
                    pass
                # 主进程: 可执行文件在 Contents/MacOS/ 且非 Helper
                if ("/Contents/MacOS/" in cmd) and ("Helper" not in cmd) and d["main_pid"] is None:
                    try:
                        d["main_pid"] = int(pid_s)
                    except ValueError:
                        pass
    return info


_run_hold = {}  # 每个 app 的"在跑"保持计数 (滞回防抖)


def detect_state(ax_trusted):
    """返回 (global_state, waiting_app_display_or_None, debug_lines)。"""
    procs = sample_processes()
    dbg = []
    waiting_app = None
    any_running = False

    for a in APPS:
        d = procs[a["key"]]
        key = a["key"]
        state = "idle"
        btns = []
        if d["running"]:
            if ax_trusted and d["main_pid"]:
                btns = ax_approval_buttons(d["main_pid"])
            if btns:
                state = "waiting"
                if waiting_app is None:
                    waiting_app = a["display"]
            else:
                # CPU 启发式 + 滞回: 超过阈值刷新保持计数, 否则递减; 计数>0 即算在跑
                if d["cpu"] > a["cpu_threshold"]:
                    _run_hold[key] = RUNNING_HOLD
                else:
                    _run_hold[key] = max(0, _run_hold.get(key, 0) - 1)
                if _run_hold.get(key, 0) > 0:
                    state = "running"
                    any_running = True
        else:
            _run_hold[key] = 0
        dbg.append(
            f"  {a['display']:<8} running={d['running']} cpu={d['cpu']:5.1f} "
            f"pid={d['main_pid']} btns={btns} -> {state}"
        )

    if waiting_app:
        gstate = "waiting"
    elif any_running:
        gstate = "running"
    else:
        gstate = "idle"
    return gstate, waiting_app, dbg


# ----------------------------------------------------------------------------
# 宠物视图
# ----------------------------------------------------------------------------
WIN_W, WIN_H = 220, 240


def load_frames():
    """加载每个状态的帧序列 -> {state: [NSImage, ...]}"""
    frames = {}
    for state, cfg in STATE_ANIM.items():
        imgs, i = [], 0
        while True:
            p = os.path.join(ASSETS, f"{cfg['prefix']}_{i}.png")
            if not os.path.exists(p):
                break
            img = NSImage.alloc().initWithContentsOfFile_(p)
            if img is None:
                break
            imgs.append(img)
            i += 1
        frames[state] = imgs
    return frames


class PetView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(PetView, self).initWithFrame_(frame)
        if self is None:
            return None
        self.state = "idle"
        self.bubble_text = None
        self.phase = 0.0
        self.frames = load_frames()
        self._drag = None
        return self

    def isFlipped(self):
        return False

    # ---- 拖拽移动窗口 ----
    def mouseDown_(self, event):
        self._drag = event.locationInWindow()

    def mouseDragged_(self, event):
        if self._drag is None:
            return
        win = self.window()
        cur = event.locationInWindow()
        o = win.frame().origin
        win.setFrameOrigin_(NSMakePoint(o.x + cur.x - self._drag.x,
                                        o.y + cur.y - self._drag.y))

    def mouseUp_(self, event):
        self._drag = None
        save_position(self.window())

    def rightMouseDown_(self, event):
        menu = NSMenu.alloc().init()
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "退出 AI 监工", "terminate:", "")
        menu.addItem_(item)
        NSMenu.popUpContextMenu_withEvent_forView_(menu, event, self)

    # ---- 绘制 ----
    def drawRect_(self, rect):
        try:
            self._drawRect_impl(rect)
        except Exception:
            import traceback
            traceback.print_exc()

    def _drawRect_impl(self, rect):
        anim = STATE_ANIM.get(self.state, STATE_ANIM["idle"])
        frames = self.frames.get(self.state) or []
        if not frames:
            NSColor.colorWithCalibratedRed_green_blue_alpha_(0.6, 0.75, 0.95, 1).set()
            NSBezierPath.bezierPathWithOvalInRect_(
                NSMakeRect(WIN_W / 2 - 40, 30, 80, 80)).fill()
            return
        idx = int(self.phase * anim["fps"]) % len(frames)
        img = frames[idx]
        sz = img.size()
        if sz.height <= 0:
            return
        th = anim["height"]
        w = sz.width * (th / sz.height)
        x = (WIN_W - w) / 2.0
        y = 12
        img.drawInRect_fromRect_operation_fraction_(
            NSMakeRect(x, y, w, th), NSZeroRect, NSCompositingOperationSourceOver, 1.0)
        if self.state == "waiting":
            self._draw_bubble(self.bubble_text or "需要授权", WIN_W / 2.0, y + th + 2)

    def _attr_text(self, s, size, color, bold=False):
        font = NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
        return NSAttributedString.alloc().initWithString_attributes_(
            s, {NSFontAttributeName: font, NSForegroundColorAttributeName: color})

    def _draw_bubble(self, text, cx, y):
        attr = self._attr_text("⚠️ " + text, 12, NSColor.blackColor(), bold=True)
        sz = attr.size()
        pad = 9
        bw = sz.width + pad * 2
        bh = sz.height + pad * 1.4
        bx = cx - bw / 2
        rect = NSMakeRect(bx, y, bw, bh)
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(rect, 9, 9)
        # 小尾巴
        tail = NSBezierPath.alloc().init()
        tail.moveToPoint_(NSMakePoint(cx - 7, y))
        tail.lineToPoint_(NSMakePoint(cx + 7, y))
        tail.lineToPoint_(NSMakePoint(cx, y - 9))
        tail.closePath()
        NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 0.93, 0.6, 0.98).set()
        path.fill()
        tail.fill()
        NSColor.colorWithCalibratedRed_green_blue_alpha_(0.85, 0.6, 0.0, 1.0).set()
        path.setLineWidth_(1.5)
        path.stroke()
        attr.drawAtPoint_(NSMakePoint(bx + pad, y + bh / 2 - sz.height / 2))


# ----------------------------------------------------------------------------
# 位置记忆
# ----------------------------------------------------------------------------
def save_position(win):
    try:
        o = win.frame().origin
        with open(POS_FILE, "w") as f:
            json.dump({"x": o.x, "y": o.y}, f)
    except Exception:
        pass


def load_position():
    try:
        with open(POS_FILE) as f:
            d = json.load(f)
            return d["x"], d["y"]
    except Exception:
        return None


# ----------------------------------------------------------------------------
# 控制器
# ----------------------------------------------------------------------------
def notify(title, text):
    try:
        subprocess.run(
            ["osascript", "-e",
             f'display notification "{text}" with title "{title}"'],
            timeout=5)
    except Exception:
        pass


class Controller(NSObject):
    def initWithView_window_(self, view, window):
        self = objc.super(Controller, self).init()
        if self is None:
            return None
        self.view = view
        self.window = window
        self.tick = 0
        self.ax_trusted = bool(AXIsProcessTrusted())
        self.prev_state = None
        self.prev_waiting = None
        if not self.ax_trusted:
            print("[!] 未获得辅助功能(Accessibility)权限 —— '需要授权'检测将无法工作。")
            print("    打开: 系统设置 > 隐私与安全性 > 辅助功能, 把运行此脚本的终端勾上。")
        return self

    def start(self):
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            ANIM_INTERVAL, self, "onAnim:", None, True)

    def onAnim_(self, timer):
        self.view.phase += ANIM_INTERVAL
        self.view.setNeedsDisplay_(True)
        self.tick += 1
        if self.tick * ANIM_INTERVAL >= POLL_INTERVAL:
            self.tick = 0
            self.poll()

    def poll(self):
        if DEMO:
            import time
            gstate = ["idle", "running", "waiting"][int(time.time() / 3) % 3]
            waiting_app = "Codex(演示)" if gstate == "waiting" else None
            self.view.state = gstate
            self.view.bubble_text = f"{waiting_app} 需要授权" if waiting_app else None
            return
        gstate, waiting_app, dbg = detect_state(self.ax_trusted)
        if DEBUG:
            print(f"[detect] global={gstate} waiting={waiting_app}")
            for line in dbg:
                print(line)
        self.view.state = gstate
        self.view.bubble_text = (f"{waiting_app} 需要授权" if waiting_app else None)

        # 进入 waiting 时推送系统通知 (同一 app 不重复)
        if gstate == "waiting" and waiting_app != self.prev_waiting:
            notify("AI 监工", f"{waiting_app} 需要授权")
        self.prev_waiting = waiting_app if gstate == "waiting" else None
        self.prev_state = gstate

    def applicationWillTerminate_(self, note):
        save_position(self.window)


def main():
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)  # 不显示 Dock 图标

    vis = NSScreen.mainScreen().visibleFrame()
    default_x = vis.origin.x + vis.size.width - WIN_W - 40
    default_y = vis.origin.y + 60
    pos = load_position()
    if pos:
        x, y = pos
        # 记忆位置若不在当前可见屏幕内(比如外接显示器拔了), 退回默认位置
        on_screen = (vis.origin.x - WIN_W * 0.5 < x < vis.origin.x + vis.size.width - WIN_W * 0.5
                     and vis.origin.y - WIN_H * 0.5 < y < vis.origin.y + vis.size.height - WIN_H * 0.5)
        if not on_screen:
            x, y = default_x, default_y
    else:
        x, y = default_x, default_y
    rect = NSMakeRect(x, y, WIN_W, WIN_H)

    window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        rect, NSWindowStyleMaskBorderless, NSBackingStoreBuffered, False)
    window.setOpaque_(False)
    window.setBackgroundColor_(NSColor.clearColor())
    window.setLevel_(NSStatusWindowLevel)
    window.setHasShadow_(False)
    window.setCollectionBehavior_(
        NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorStationary
        | NSWindowCollectionBehaviorFullScreenAuxiliary)

    view = PetView.alloc().initWithFrame_(NSMakeRect(0, 0, WIN_W, WIN_H))
    window.setContentView_(view)
    window.makeKeyAndOrderFront_(None)
    window.orderFrontRegardless()
    app.activateIgnoringOtherApps_(True)
    nframes = {k: len(v) for k, v in view.frames.items()}
    print(f"[window] isVisible={window.isVisible()} frame={window.frame()} frames={nframes}")

    ctrl = Controller.alloc().initWithView_window_(view, window)
    app.setDelegate_(ctrl)
    ctrl.start()

    print("AI 监工 已启动。右键宠物可退出。" + (" [DEBUG]" if DEBUG else ""))
    app.run()


if __name__ == "__main__":
    main()
