import ColorLinkCore
import SwiftUI

struct PairView: View {
    @EnvironmentObject var link: LinkController

    @State private var selected: DiscoveredPhone?
    @State private var manualAddress = ""
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("手机", selection: $selected) {
                    ForEach(link.discovered, id: \.self) { Text($0.name).tag(Optional($0)) }
                    Text("手动输入地址").tag(DiscoveredPhone?.none)
                }
                if selected == nil {
                    TextField("地址", text: $manualAddress, prompt: Text("192.168.1.23:8765"))
                }
            } header: {
                Text(link.discovered.isEmpty ? "局域网里还没发现手机" : "局域网里发现的手机")
            }

            Section {
                TextField("配对码", text: $code, prompt: Text("手机 App 上显示的 6 位数字"))
                    .onSubmit { Task { await pair() } }
            }

            if let message {
                Text(message).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("配对") { Task { await pair() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || code.count != 6 || (selected == nil && manualAddress.isEmpty))
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .onAppear { if selected == nil { selected = link.discovered.first } }
    }

    private func pair() async {
        busy = true
        defer { busy = false }
        do {
            try await link.pair(phone: selected, manualAddress: manualAddress, code: code)
            code = ""
            message = nil
            Windows.shared.closePair()
        } catch {
            message = error.localizedDescription
        }
    }
}
