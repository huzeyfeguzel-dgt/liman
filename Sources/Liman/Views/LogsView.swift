import SwiftUI
import LimanCore

struct LogsView: View {
    @Environment(AppState.self) private var state
    @State private var text = ""
    @State private var follow = true
    @State private var filter = ""
    @State private var error: String?

    private var target: ContainerSummary? {
        state.containers.first { $0.id == state.logTargetID } ?? state.containers.first
    }

    private var shown: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }
            .joined(separator: "\n")
    }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            HStack {
                Picker(L("Konteyner", "Container"), selection: Binding(get: { target?.id }, set: { state.logTargetID = $0 })) {
                    ForEach(state.containers) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 260)
                TextField(L("Filtrele", "Filter"), text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Toggle(L("Takip et", "Follow"), isOn: $follow)
                Spacer()
                Button { copy() } label: { Label(L("Kopyala", "Copy"), systemImage: "doc.on.doc") }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(shown.isEmpty ? (error ?? L("Log yok", "No logs")) : shown)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                // .bottomLeading: yalnızca dikeyde sona kay; .bottom yatayda da ortalayıp satır başlarını kesiyordu.
                .onChange(of: text) { if follow { proxy.scrollTo("end", anchor: .bottomLeading) } }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle(target.map { L("Loglar — \($0.name)", "Logs — \($0.name)") } ?? L("Loglar", "Logs"))
        .task(id: target?.id) { await poll() }
    }

    private func poll() async {
        text = ""
        while !Task.isCancelled {
            if let t = target {
                do {
                    let s = try await state.client.logs(t.id, tail: 1000)
                    if s != text { text = s }
                    error = nil
                } catch let e {
                    error = e.localizedDescription
                }
            }
            guard follow else { break }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown, forType: .string)
    }
}
