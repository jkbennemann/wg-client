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

            LogTextView(text: displayText)
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

/// Read-only, selectable log text scrolled to the end. Backed by NSTextView because a
/// SwiftUI `Text` lays out its whole string on the main thread: the 256 KiB tail the
/// helper sends froze the window for ~5 s on every open, refresh, and resize.
private struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }
}
