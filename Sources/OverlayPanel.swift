import Cocoa
import SwiftUI

/// A floating, non-activating panel at the bottom center of the screen.
/// Shows real-time transcription text with a frosted glass appearance.
/// Height is manually driven by SwiftUI content measurement; bottom edge stays anchored.
class OverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()
    private let panelWidth: CGFloat = 500

    func show() {
        if panel != nil {
            viewModel.isVisible = true
            panel?.orderFront(nil)
            return
        }

        let content = OverlayContentView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []  // We drive panel sizing manually

        let initialHeight: CGFloat = 60
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: initialHeight)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: initialHeight),
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

        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        // Position: bottom of panel at screen bottom + 60
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.minY + 60
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // SwiftUI reports measured content height → we resize the panel
        viewModel.onPanelHeightChange = { [weak self] height in
            self?.resizePanel(height: height)
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
    }

    func setState(_ state: OverlayState) {
        viewModel.state = state
    }

    private func resizePanel(height: CGFloat) {
        guard let p = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let clamped = max(height, 50)
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.minY + 60
        let newFrame = NSRect(x: x, y: y, width: panelWidth, height: clamped)
        if p.frame != newFrame {
            p.setFrame(newFrame, display: true)
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
    /// Called from SwiftUI when the desired panel height changes.
    var onPanelHeightChange: ((CGFloat) -> Void)?
}

// MARK: - SwiftUI View

/// Measures the rendered height of text content.
private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @State private var textHeight: CGFloat = 20

    // Non-text overhead: vertical padding (14*2) + status label (~15) + VStack spacing (2)
    private let chromeHeight: CGFloat = 46

    private var maxPanelHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return screenHeight - 200
    }

    /// Max height for the scrollable text area
    private var maxScrollHeight: CGFloat {
        maxPanelHeight - chromeHeight
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(viewModel.text.isEmpty ? "正在聆听..." : viewModel.text)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: TextHeightKey.self, value: geo.size.height)
                            })
                            .id("bottom")
                    }
                    .frame(height: min(textHeight, maxScrollHeight))
                    .onPreferenceChange(TextHeightKey.self) { height in
                        textHeight = height
                        let panelH = min(height + chromeHeight, maxPanelHeight)
                        viewModel.onPanelHeightChange?(panelH)
                    }
                    .onChange(of: viewModel.text) { _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
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
        .frame(width: 500)
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
