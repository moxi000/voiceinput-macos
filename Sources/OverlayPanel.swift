import Cocoa
import SwiftUI

/// A floating, non-activating panel at the bottom center of the screen.
/// Shows real-time transcription text with a frosted glass appearance.
class OverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()
    private let panelWidth: CGFloat = 500
    private let panelHeight: CGFloat = 400  // fixed tall panel, content auto-sizes

    func show() {
        if panel != nil {
            viewModel.isVisible = true
            panel?.orderFront(nil)
            return
        }

        let content = OverlayContentView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false

        // Lock the panel size — prevent any auto-resizing
        p.contentMinSize = NSSize(width: panelWidth, height: panelHeight)
        p.contentMaxSize = NSSize(width: panelWidth, height: panelHeight)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        // Position: bottom of panel at screen bottom + 60
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.minY + 60
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFront(nil)
        panel = p
        viewModel.isVisible = true
    }

    func hide() {
        viewModel.isVisible = false
        panel?.orderOut(nil)
    }

    func updateText(_ text: String) {
        viewModel.text = text
        // Force panel to stay at correct position (NSHostingView may auto-resize)
        enforcePosition()
    }

    func setState(_ state: OverlayState) {
        viewModel.state = state
    }

    private func enforcePosition() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.minY + 60
        let correctFrame = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        if p.frame != correctFrame {
            p.setFrame(correctFrame, display: false)
        }
    }
}

// MARK: - State

enum OverlayState {
    case recording
    case transcribing
    case done
    case error(String)
}

class OverlayViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var state: OverlayState = .recording
    @Published var isVisible: Bool = false
}

// MARK: - SwiftUI View

struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        VStack {
            Spacer()  // push content to bottom of the tall panel

            HStack(alignment: .top, spacing: 12) {
                // Status indicator
                statusIcon
                    .frame(width: 24, height: 24)

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(viewModel.text.isEmpty ? "正在聆听..." : viewModel.text)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: 500, maxHeight: .infinity, alignment: .bottom)
    }

    private var statusIcon: some View {
        Group {
            switch viewModel.state {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .fill(.red.opacity(0.4))
                            .frame(width: 20, height: 20)
                    )
            case .transcribing:
                ProgressView()
                    .scaleEffect(0.7)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 18))
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 18))
            }
        }
    }

    private var statusLabel: String {
        switch viewModel.state {
        case .recording: return "🎙 录音中"
        case .transcribing: return "⏳ 识别中"
        case .done: return "✅ 完成"
        case .error(let msg): return "❌ \(msg)"
        }
    }
}
