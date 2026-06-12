#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""最小可见性测试: 弹一个普通的、带标题栏的白色窗口, 并打印屏幕/窗口信息。
用法: ./.venv/bin/python probe.py   (或 ./run.sh 同款 venv)
看到一个标题为 'AI监工 测试' 的窗口 = GUI 正常; 看不到 = 环境问题。
"""
from AppKit import *
from Foundation import NSMakeRect, NSMakePoint

app = NSApplication.sharedApplication()
app.setActivationPolicy_(NSApplicationActivationPolicyRegular)  # 普通 app, 会进 Dock

print("=== 屏幕 ===")
for i, s in enumerate(NSScreen.screens()):
    f = s.frame()
    print(f"  screen[{i}] origin=({f.origin.x},{f.origin.y}) size=({f.size.width}x{f.size.height})")
main = NSScreen.mainScreen().frame()

W, H = 360, 220
x = main.origin.x + (main.size.width - W) / 2
y = main.origin.y + (main.size.height - H) / 2
rect = NSMakeRect(x, y, W, H)

style = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
win = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
    rect, style, NSBackingStoreBuffered, False)
win.setTitle_("AI监工 测试")
win.setLevel_(NSStatusWindowLevel)
win.setBackgroundColor_(NSColor.whiteColor())

label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, 80, W - 40, 60))
label.setStringValue_("如果你看到我，GUI 正常 ✅\n关掉我，回去告诉 Claude")
label.setBezeled_(False); label.setEditable_(False); label.setSelectable_(False)
label.setBackgroundColor_(NSColor.whiteColor())
win.contentView().addSubview_(label)

win.makeKeyAndOrderFront_(None)
win.orderFrontRegardless()
app.activateIgnoringOtherApps_(True)

print("=== 窗口 ===")
print("  rect=", rect)
print("  isVisible=", win.isVisible(), " isKey=", win.isKeyWindow())
print("窗口已弹出。看不到的话, 把上面这些打印内容发给 Claude。Ctrl+C 退出。")
app.run()
