# Xiao Anzhu Is Here 🏃

[中文](README.md) · **English**

## In one sentence

A desktop pet that watches your AI tools for you: it shows what is running, what needs approval, and what has already finished.

When several AI agents work at once, it is easy to forget which one is busy, blocked, or done. Xiao Anzhu runs while an AI task is active, raises a hand when you need to approve something, jumps when work finishes, and sleeps when nothing needs attention.

## When it helps

- You keep Claude, Codex, Qoder, or several other AI tools open at once.
- Long background tasks often sit waiting for approval.
- You need to know which tool, project, and session a task belongs to.
- You want to capture a quick task or idea by voice without changing windows.

## Features

- Live states: idle, running, or waiting for approval.
- Bubble and macOS notifications when a task finishes or needs you.
- A task label showing the current tool, project, and task.
- A drill-down panel from AI tool to project to session.
- Voice capture with `Control + Option + V`.
- A task inbox with reminders and completion states.
- Local usage display for Claude and Codex limits.

## Supported tools

| Tool | Setup | Available information |
| --- | --- | --- |
| Claude Desktop, including Cowork | None | State, task name, usage |
| Codex Desktop | None | State, project, task name, usage |
| Aone Copilot in IntelliJ | None | State, project |
| Qoder | Hooks required | State, project, session |

Other tools can be added when they expose hooks or readable local logs.

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/HopeeeeZhu/ai-monitor-pet/releases).
2. Open it and drag the app into Applications.
3. On the first launch, right-click the app and choose **Open**.
4. Grant Accessibility permission for approval detection.
5. Grant microphone, speech recognition, and notification permissions only if you use those features.

If macOS reports that the app is damaged, run:

```bash
xattr -cr /Applications/小安竺来咯.app
```

## Everyday use

- Drag the pet to move it.
- Left-click to open or close the status panel.
- Right-click to resize or quit.
- Press `Control + Option + V` to start voice capture and press it again to save.

## Privacy notes

- Codex usage is read from local session logs; no network request is made.
- Claude usage comes from the official OAuth usage endpoint. Credentials are read-only and are never refreshed or written back by this app.

## Build locally

Requires macOS 14+ and the Xcode command-line tools:

```bash
cd AIMonitorPet
swift build -c release
cp .build/release/AIMonitorPet "dist/AI监工.app/Contents/MacOS/AI监工"
codesign --force --deep --sign - "dist/AI监工.app"
open -n "dist/AI监工.app"
```
