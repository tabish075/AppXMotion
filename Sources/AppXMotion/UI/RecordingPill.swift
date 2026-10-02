import AppKit
import SwiftUI

/// A small always-on-top "● 0:12  Stop" bar shown while recording, so you can stop
/// without leaving the app you're demoing.
@MainActor
final class RecordingPill {
    private var panel: NSPanel?

    func show(title: String, startedAt: Date, onStop: @escaping () -> Void) {
        hide()
        let view = PillView(title: title, startedAt: startedAt) { [weak self] in
            onStop()
            self?.hide()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 44)
        let panel = NSPanel(contentRect: hosting.frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.sharingType = .none  // never shows up in screen recordings
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 130, y: frame.maxY - 60))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PillView: View {
    let title: String
    let startedAt: Date
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 9, height: 9)
            SwiftUI.TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                Text(formatTime(context.date.timeIntervalSince(startedAt)).dropLast(3))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: onStop) {
                Text("Stop").font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(width: 260, height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }
}
