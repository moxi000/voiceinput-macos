import Cocoa
import SwiftUI

/// A floating, non-activating panel at the bottom center of the screen.
/// Shows real-time transcription text with a frosted glass appearance.
/// Height is manually driven by SwiftUI content measurement; bottom edge stays anchored.
class OverlayPanel {
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()
    private let panelWidth: CGFloat = 500
    private let minimalPanelWidth: CGFloat = 170
    private let minimalPanelHeight: CGFloat = 40

    /// When true, shows only the status icon (no text). Used in inline mode.
    var minimal: Bool = false {
        didSet { viewModel.minimal = minimal }
    }

    /// When true, shows local ASR indicator; otherwise cloud indicator.
    var isLocal: Bool = false {
        didSet { viewModel.isLocal = isLocal }
    }

    func show() {
        if panel != nil {
            resizePanelForMode()
            viewModel.isVisible = true
            panel?.orderFront(nil)
            return
        }

        let currentWidth = minimal ? minimalPanelWidth : panelWidth
        let initialHeight: CGFloat = minimal ? minimalPanelHeight : 60

        let content = OverlayContentView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []  // We drive panel sizing manually
        hosting.frame = NSRect(x: 0, y: 0, width: currentWidth, height: initialHeight)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: currentWidth, height: initialHeight),
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
        p.titlebarAppearsTransparent = true

        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        // Position: bottom-center of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - currentWidth / 2
            let y = screenFrame.minY + 60
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // SwiftUI reports measured content height → we resize the panel (overlay mode only)
        viewModel.onPanelHeightChange = { [weak self] height in
            guard self?.minimal != true else { return }
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

    func updateAudioLevel(_ level: Float) {
        var levels = viewModel.audioLevels
        levels.removeFirst()
        levels.append(CGFloat(level))
        viewModel.audioLevels = levels
    }

    /// Resize panel to match current mode (minimal vs full).
    private func resizePanelForMode() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        if minimal {
            let x = screenFrame.midX - minimalPanelWidth / 2
            let y = screenFrame.minY + 60
            let newFrame = NSRect(x: x, y: y, width: minimalPanelWidth, height: minimalPanelHeight)
            p.setFrame(newFrame, display: true)
        } else {
            // Restore overlay dimensions; SwiftUI preference will refine height later
            let currentHeight = max(p.frame.height, 60)
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.minY + 60
            let newFrame = NSRect(x: x, y: y, width: panelWidth, height: currentHeight)
            p.setFrame(newFrame, display: true)
        }
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
    @Published var minimal: Bool = false
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 5)
    @Published var isLocal: Bool = false
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

    private var cornerRadius: CGFloat {
        viewModel.minimal ? 20 : 16
    }

    var body: some View {
        Group {
            if viewModel.minimal {
                minimalPill
            } else {
                fullOverlay
            }
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Minimal pill (inline mode)

    private var minimalPill: some View {
        HStack(spacing: 8) {
            minimalStatusIcon

            Text(minimalStatusText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.primary.opacity(0.85))
                .lineLimit(1)

            if case .recording = viewModel.state {
                WaveformView(levels: viewModel.audioLevels)
                    .frame(width: 28, height: 16)
            }

            providerIcon
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var minimalStatusIcon: some View {
        Group {
            switch viewModel.state {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: .red.opacity(0.6), radius: 4)
            case .transcribing:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 8, height: 8)
            case .done:
                Image(systemName: "checkmark")
                    .foregroundColor(.green)
                    .font(.system(size: 10, weight: .bold))
            case .error:
                Image(systemName: "xmark")
                    .foregroundColor(.red)
                    .font(.system(size: 10, weight: .bold))
            }
        }
    }

    private var minimalStatusText: String {
        switch viewModel.state {
        case .recording: return "聆听中"
        case .transcribing: return "识别中"
        case .done: return "完成"
        case .error: return "出错"
        }
    }

    // MARK: - Full overlay (paste mode)

    private var fullOverlay: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    providerIcon
                }

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

    private var providerIcon: some View {
        Image(systemName: viewModel.isLocal ? "desktopcomputer" : "cloud.fill")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary.opacity(0.7))
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

// MARK: - Waveform Visualization

struct WaveformView: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<levels.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.primary.opacity(0.6))
                    .frame(width: 3, height: barHeight(for: levels[i]))
                    .animation(.easeOut(duration: 0.12), value: levels[i])
            }
        }
    }

    private func barHeight(for level: CGFloat) -> CGFloat {
        let minH: CGFloat = 3
        let maxH: CGFloat = 16
        return minH + (maxH - minH) * level
    }
}
