import SwiftUI

struct VoiceCaptureHUDView: View {
    @ObservedObject var service: VoiceCaptureService
    let onStop: () -> Void
    let onSave: (CaptureKind, String, Date?) -> Void
    let onCancel: () -> Void

    @State private var selectedKind: CaptureKind = .todo
    @State private var draftText: String = ""
    @State private var wantsReminder = false
    @State private var reminderAt = Date().addingTimeInterval(3600)
    @State private var hasEdited = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch service.phase {
            case .requestingPermission:
                statusLine(text: "准备录音", color: .orange, showPulse: false)
                Text("正在请求权限...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

            case .recording:
                HStack {
                    statusLine(text: "正在听 \(formatElapsed(service.elapsedSeconds))", color: .red, showPulse: true)
                    Spacer()
                    Button(action: onStop) {
                        Label("停止", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .help("停止录音")
                }
                Text(service.transcript.isEmpty ? "把想法说出来..." : service.transcript)
                    .font(.system(size: 12))
                    .foregroundColor(service.transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("再按 Control + Option + V 也可以停止")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

            case .reviewing:
                Picker("", selection: $selectedKind) {
                    ForEach(CaptureKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: Binding(
                    get: { draftText },
                    set: {
                        draftText = $0
                        hasEdited = true
                    }
                ))
                .font(.system(size: 12))
                .frame(height: 58)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
                .cornerRadius(6)

                if selectedKind == .todo {
                    Toggle("提醒", isOn: $wantsReminder)
                        .font(.system(size: 12))
                    if wantsReminder {
                        DatePicker(
                            "时间",
                            selection: $reminderAt,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .font(.system(size: 12))
                    }
                }

                HStack {
                    Spacer()
                    Button("取消", action: onCancel)
                        .buttonStyle(.plain)
                    Button("保存") {
                        let reminder = selectedKind == .todo && wantsReminder ? reminderAt : nil
                        onSave(selectedKind, draftText, reminder)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

            case .saved:
                statusLine(text: "记下啦", color: .green, showPulse: false)
                Text("已保存到捕获箱")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

            case .failed(let message):
                HStack {
                    statusLine(text: message, color: .orange, showPulse: false)
                    Spacer()
                    Button("关闭", action: onCancel)
                        .buttonStyle(.plain)
                }

            case .idle:
                EmptyView()
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .onAppear {
            syncDraftIfNeeded()
        }
        .onChange(of: service.phase) { _, newPhase in
            if newPhase == .reviewing {
                selectedKind = .todo
                wantsReminder = false
                reminderAt = Date().addingTimeInterval(3600)
                hasEdited = false
                draftText = service.transcript
            } else {
                syncDraftIfNeeded()
            }
        }
        .onChange(of: service.transcript) { _, _ in
            syncDraftIfNeeded()
        }
    }

    private func statusLine(text: String, color: Color, showPulse: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(showPulse && pulse ? 0.18 : 0.0))
                    .frame(width: 18, height: 18)
                    .scaleEffect(showPulse && pulse ? 1.3 : 0.8)
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            .onAppear {
                guard showPulse else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }

            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
    }

    private func syncDraftIfNeeded() {
        if service.phase == .reviewing && !hasEdited {
            draftText = service.transcript
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
