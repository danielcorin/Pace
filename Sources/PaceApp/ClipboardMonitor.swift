import AppKit
import Foundation
import PaceCore

@MainActor
final class ClipboardMonitor {
    typealias Handler = @MainActor (PasteboardSnapshot) -> Void

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private let handler: Handler
    private var timer: Timer?
    private var lastChangeCount: Int

    init(
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.15,
        handler: @escaping Handler
    ) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.handler = handler
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = interval * 0.25
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func acknowledgeCurrentClipboard() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let snapshot = PasteboardSnapshot.capture(from: pasteboard) else { return }
        handler(snapshot)
    }
}
