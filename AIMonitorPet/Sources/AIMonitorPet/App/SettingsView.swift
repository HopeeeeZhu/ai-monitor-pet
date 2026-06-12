import SwiftUI

struct SettingsView: View {
    @State private var petHeight: Double = UserDefaults.standard.double(forKey: "petHeight").nonZero ?? 200
    @AppStorage("petHeight") private var savedHeight: Double = 200

    var petWindow: PetWindow?

    var body: some View {
        VStack(spacing: 20) {
            Text("小安竺来咯设置")
                .font(.title2)
                .fontWeight(.bold)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("宠物大小")
                    .font(.headline)

                HStack {
                    Text("小")
                        .font(.caption)
                    Slider(value: $petHeight, in: 100...400, step: 10) { editing in
                        if !editing {
                            applySize()
                        }
                    }
                    Text("大")
                        .font(.caption)
                }

                Text("高度: \(Int(petHeight))px")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Button("恢复默认") {
                    petHeight = 200
                    applySize()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("退出小安竺来咯") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .padding(24)
        .frame(width: 320, height: 240)
    }

    private func applySize() {
        savedHeight = petHeight
        petWindow?.resizePet(height: CGFloat(petHeight))
    }
}

extension Double {
    var nonZero: Double? {
        self > 0 ? self : nil
    }
}
