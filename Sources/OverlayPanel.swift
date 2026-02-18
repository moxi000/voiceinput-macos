import Cocoa
import SwiftUI

/// A floating, non-activating panel at the bottom center of the screen.
/// Shows real-time transcription text with a frosted glass appearance.
/// Height auto-sizes to fit content (scrollable when exceeding max); bottom edge stays anchored.
class OverlayPanel {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayContentView>?
    private let viewModel = OverlayViewModel()
    private let panelWidth: CGFloat = 500
    private var resizeObserver: Any?

    func show() {
        if panel != nil {
            viewModel.isVisible = true
            panel?.orderFront(nil)
            return
        }

        let content = OverlayContentView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]

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

        // Lock width, allow height to vary with content up to screen limit
        p.contentMinSize = NSSize(width: panelWidth, height: 0)
        if let screen = NSScreen.main {
            let maxH = screen.visibleFrame.height - 200
            p.contentMaxSize = NSSize(width: panelWidth, height: maxH)
        } else {
            p.contentMaxSize = NSSize(width: panelWidth, height: 10000)
        }
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        hostingView = hosting

        // Position: bottom of panel at screen bottom + 60
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.minY + 60
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // When NSHostingView auto-resizes the panel, it keeps top-left fixed.
        // We want bottom-left fixed, so re-anchor on every resize.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            self?.enforcePosition()
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
        enforcePosition()
    }

    func setState(_ state: OverlayState) {
        viewModel.state = state
        enforcePosition()
    }

    /// Keep the panel's bottom edge at screenFrame.minY + 60, centered horizontally.
    private func enforcePosition() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.minY + 60
        let origin = NSPoint(x: x, y: y)
        if p.frame.origin != origin {
            p.setFrameOrigin(origin)
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

/// Measures the actual rendered height of content and reports it via PreferenceKey.
private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 20
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @State private var textHeight: CGFloat = 20

    private var maxContentHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return screenHeight - 200
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Status indicator
            statusIcon
                .frame(width: 24, height: 24)

            // Text
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
                    .frame(height: min(textHeight, maxContentHeight))
                    .onPreferenceChange(TextHeightKey.self) { height in
                        textHeight = height
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
