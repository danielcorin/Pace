import AppKit
import Foundation
import ImageIO
import PaceCore
import QuickLookUI

struct ImagePreviewContent: Sendable {
    let data: Data
    let typeIdentifier: String
}

private final class PaceQuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    let recordID: UUID

    init(url: URL, title: String, recordID: UUID) {
        previewItemURL = url
        previewItemTitle = title
        self.recordID = recordID
    }
}

private struct PreparedQuickLook {
    let fileURL: URL
    let directoryURL: URL
    let transitionImage: NSImage
    let pixelSize: CGSize
}

/// Prepares the complete image and its aspect-correct window frame before
/// handing it to Quick Look. QLPreviewPanel can otherwise appear at its generic
/// square size and resize only after its asynchronous image inspection.
@MainActor
final class ImageQuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private var item: PaceQuickLookItem?
    private var transitionImage: NSImage?
    private var pixelSize: CGSize = .zero
    private var temporaryDirectoryURL: URL?
    private var presentationTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var resizeObserver: NSObjectProtocol?
    private var requestID = UUID()
    var onDismiss: (() -> Void)?

    var hasItem: Bool { item != nil }

    var isVisible: Bool {
        hasItem
            && QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared()?.isVisible == true
    }

    func toggle(record: ClipboardRecord, model: AppModel) {
        if isVisible, item?.recordID == record.id {
            close()
            return
        }
        present(record: record, model: model)
    }

    func present(record: ClipboardRecord, model: AppModel) {
        presentationTask?.cancel()
        let currentRequestID = UUID()
        requestID = currentRequestID
        presentationTask = Task { [weak self] in
            guard let content = await model.itemImageContent(for: record), !Task.isCancelled else { return }
            let prepared = await Task.detached(priority: .userInitiated) {
                try? Self.prepare(content)
            }.value
            guard let prepared else { return }
            guard let self, !Task.isCancelled, self.requestID == currentRequestID else {
                try? FileManager.default.removeItem(at: prepared.directoryURL)
                return
            }
            self.show(prepared, recordID: record.id)
        }
    }

    func close() {
        presentationTask?.cancel()
        requestID = UUID()
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else {
            finishDismissal()
            return
        }
        panel.orderOut(nil)
        finishDismissal()
    }

    func configure(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func relinquish(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        if !panel.isVisible { finishDismissal() }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        item == nil ? 0 : 1
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        guard index == 0 else { return nil }
        return item
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        transitionImageFor item: any QLPreviewItem,
        contentRect: NSRectPointer
    ) -> Any! {
        guard let transitionImage else { return nil }
        contentRect.pointee = NSRect(origin: .zero, size: transitionImage.size)
        return transitionImage
    }

    func windowWillClose(_ notification: Notification) {
        finishDismissal()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel, !panel.isVisible else { return }
        finishDismissal()
    }

    private func show(_ prepared: PreparedQuickLook, recordID: UUID) {
        clearPreparedContent()
        temporaryDirectoryURL = prepared.directoryURL
        transitionImage = prepared.transitionImage
        pixelSize = prepared.pixelSize
        item = PaceQuickLookItem(
            url: prepared.fileURL,
            title: "Clipboard Image",
            recordID: recordID
        )

        guard let panel = QLPreviewPanel.shared() else {
            finishDismissal()
            return
        }
        configure(panel)
        size(panel, for: prepared.pixelSize)
        // Quick Look has no public "preview finished loading" callback. Keep
        // its panel transparent while it performs its own asynchronous sizing,
        // then reveal it after the resulting resize animation settles.
        panel.alphaValue = 0
        observeInitialResize(of: panel, recordID: recordID)
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        scheduleReveal(of: panel, recordID: recordID, afterNanoseconds: 350_000_000)
    }

    private func size(_ panel: QLPreviewPanel, for pixelSize: CGSize) {
        let screen = NSApp.keyWindow?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let contentSize = Self.previewSize(for: pixelSize, on: screen)
        panel.contentAspectRatio = contentSize
        panel.setContentSize(contentSize)

        var frame = panel.frame
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        // The panel is still hidden, so its first displayed frame already has
        // the image's final size and aspect ratio.
        panel.setFrame(frame, display: false)
    }

    private func observeInitialResize(of panel: QLPreviewPanel, recordID: UUID) {
        stopWaitingToReveal()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let panel else { return }
            Task { @MainActor in
                // A resize queued just before the reveal began would cancel
                // and restart its fade; the reveal removes the observer first.
                guard let self, self.resizeObserver != nil else { return }
                self.scheduleReveal(
                    of: panel,
                    recordID: recordID,
                    afterNanoseconds: 60_000_000
                )
            }
        }
    }

    private func scheduleReveal(
        of panel: QLPreviewPanel,
        recordID: UUID,
        afterNanoseconds delay: UInt64
    ) {
        revealTask?.cancel()
        revealTask = Task { [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, let panel,
                  self.item?.recordID == recordID, panel.isVisible else { return }
            // Only the observer goes; cancelling revealTask here would cancel
            // this fade.
            self.stopObservingResize()
            // The fade starts from the completed native Quick Look panel at
            // its settled size. It steps inside revealTask rather than using
            // the window animator so a replacement preview or a dismissal
            // (both cancel revealTask) stops it cleanly.
            let steps = 7
            for step in 1...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                panel.alphaValue = 1 - (1 - progress) * (1 - progress)
                guard step < steps else { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled, self.item?.recordID == recordID else { return }
            }
        }
    }

    private func stopWaitingToReveal() {
        revealTask?.cancel()
        revealTask = nil
        stopObservingResize()
    }

    private func stopObservingResize() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
    }

    private func finishDismissal() {
        guard item != nil || temporaryDirectoryURL != nil else { return }
        stopWaitingToReveal()
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared()?.alphaValue = 1
        }
        clearPreparedContent()
        onDismiss?()
    }

    private func clearPreparedContent() {
        item = nil
        transitionImage = nil
        pixelSize = .zero
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            self.temporaryDirectoryURL = nil
        }
    }

    nonisolated private static func prepare(_ content: ImagePreviewContent) throws -> PreparedQuickLook {
        guard let source = CGImageSourceCreateWithData(content.data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelSize = CGSize(
            width: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0,
            height: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Pace-Quick-Look-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let file = directory.appendingPathComponent(
                "Clipboard Image.\(filenameExtension(for: content.typeIdentifier))"
            )
            try content.data.write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return PreparedQuickLook(
                fileURL: file,
                directoryURL: directory,
                transitionImage: NSImage(cgImage: thumbnail, size: .zero),
                pixelSize: pixelSize
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    nonisolated private static func previewSize(for pixelSize: CGSize, on screen: NSScreen?) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: 640, height: 480)
        }
        let backingScale = screen?.backingScaleFactor ?? 2
        let naturalSize = CGSize(
            width: pixelSize.width / backingScale,
            height: pixelSize.height / backingScale
        )
        let visibleSize = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maximumSize = CGSize(
            width: min(visibleSize.width * 0.78, 1100),
            height: min(visibleSize.height * 0.78, 800)
        )
        var scale = min(1, maximumSize.width / naturalSize.width, maximumSize.height / naturalSize.height)
        let displayedLongSide = max(naturalSize.width, naturalSize.height) * scale
        if displayedLongSide < 280 {
            scale *= min(4, 280 / max(displayedLongSide, 1))
        }
        return CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
    }

    nonisolated private static func filenameExtension(for typeIdentifier: String) -> String {
        switch typeIdentifier {
        case "public.jpeg": return "jpg"
        case "public.tiff": return "tiff"
        default: return "png"
        }
    }
}
