import SwiftUI
import AppKit
import Shared

struct LogView: View {
    @State private var text: String = ""
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Helper Log")
                    .font(.headline)
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    NSWorkspace.shared.selectFile(IPC.logPath, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Button(action: load) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
            }
            .padding(10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("logEnd")
                }
                .onChange(of: text) { _ in
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear(perform: load)
    }

    private var displayText: String {
        if let errorMessage { return errorMessage }
        if text.isEmpty && !loading { return "(log is empty)" }
        return text
    }

    private func load() {
        loading = true
        errorMessage = nil
        DispatchQueue.global().async {
            var result: String = ""
            var failure: String?
            do {
                result = try HelperClient.fetchLog()
            } catch {
                failure = "Could not read the log: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                loading = false
                if let failure {
                    errorMessage = failure
                } else {
                    text = result
                }
            }
        }
    }
}
