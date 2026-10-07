import AppKit
import SwiftUI

@MainActor
@Observable
final class OverlayModel {
    enum Phase { case listening, cleaning, error }
    var phase: Phase = .listening
    var text = ""
}

/// Floating live-preview pill near the bottom of the screen. Never takes focus.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private let hosting: NSHostingView<OverlayView>
    private var hideWork: DispatchWorkItem?

    init() {
        hosting = NSHostingView(rootView: OverlayView(model: model))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: OverlayView.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
    }

    func show(_ phase: OverlayModel.Phase, text: String = "") {
        hideWork?.cancel()
        model.phase = phase
        model.text = text
        layout()
        panel.orderFrontRegardless()
    }

    func update(text: String) {
        model.text = text
        layout()
    }

    func set(_ phase: OverlayModel.Phase) {
        model.phase = phase
        layout()
    }

    func showError(_ message: String) {
        show(.error, text: message)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
        model.text = ""
    }

    var isVisible: Bool { panel.isVisible }

    /// The panel is a fixed, transparent, click-through canvas; SwiftUI sizes the pill inside it.
    /// (Resizing the window to fit the text lagged a frame behind, so text spilled out of the pill.)
    private func layout() {
        let size = OverlayView.canvas
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 44)
        if panel.frame.origin != origin { panel.setFrame(NSRect(origin: origin, size: size), display: false) }
    }
}

struct OverlayView: View {
    static let canvas = NSSize(width: 680, height: 220)
    let model: OverlayModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }

    private var pill: some View {
        HStack(alignment: .top, spacing: 10) {
            indicator
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            Text(displayText)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(width: textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let fontSize: CGFloat = 14
    private static let maxTextWidth: CGFloat = 560
    /// Roughly 4 lines at max width; beyond this only the latest words are shown.
    private static let maxCharacters = 300

    private var displayText: String {
        let text = model.phase == .listening && model.text.isEmpty ? "Listening…" : model.text
        guard text.count > Self.maxCharacters else { return text }
        var tail = String(text.suffix(Self.maxCharacters))
        if let space = tail.firstIndex(of: " ") { tail = String(tail[tail.index(after: space)...]) }
        return "…" + tail
    }

    /// Measured explicitly so the pill hugs short text and wraps long text at a fixed width.
    private var textWidth: CGFloat {
        let natural = (displayText as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Self.fontSize)]).width
        return min(ceil(natural) + 2, Self.maxTextWidth)
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .listening:
            Image(systemName: "waveform")
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .cleaning:
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
    }
}
