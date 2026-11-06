import SwiftUI
import AppKit
import PDFKit
import ImageIO

struct AttachmentHoverRequest {
    var attachment: Attachment
    var url: URL
    var location: CGPoint // Parent window coordinates; independent of list scrolling.
}

@MainActor final class AttachmentHoverSession: ObservableObject {
    @Published private(set) var request: AttachmentHoverRequest?
    @Published private(set) var image: NSImage?
    @Published private(set) var visible = false
    @Published private(set) var error: String?
    private var loading: Task<Void, Never>?
    private let cache = NSCache<NSURL, NSImage>()
    init() { cache.countLimit = 16; cache.totalCostLimit = 24 * 1024 * 1024 }
    func track(_ attachment: Attachment, url: URL, location: CGPoint?) {
        guard let location else {
            if request?.attachment.id == attachment.id { clear() }
            return
        }
        if request?.attachment.id == attachment.id && request?.url == url {
            request?.location = location; return
        }
        clear()
        request = AttachmentHoverRequest(attachment: attachment, url: url, location: location)
        loading = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard let self, self.request?.attachment.id == attachment.id else { return }
            if let cached = self.cache.object(forKey: url as NSURL) {
                self.image = cached; self.visible = true; return
            }
            let image = await Task.detached(priority: .userInitiated) { Self.thumbnail(url) }.value
            guard !Task.isCancelled, self.request?.attachment.id == attachment.id, self.request?.url == url else { return }
            self.image = image
            self.error = image == nil ? "附件暂时无法预览" : nil
            if let image { self.cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4)) }
            self.visible = true
        }
    }
    func clear() {
        loading?.cancel(); loading = nil
        request = nil; image = nil; error = nil; visible = false
    }
    nonisolated private static func thumbnail(_ url: URL) -> NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked, let page = pdf.page(at: 0) else { return nil }
            return page.thumbnail(of: NSSize(width: 800, height: 800), for: .mediaBox)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 800, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct AttachmentHoverTracking: NSViewRepresentable {
    var hover: (CGPoint?) -> Void
    func makeNSView(context: Context) -> AttachmentHoverTrackingView { AttachmentHoverTrackingView() }
    func updateNSView(_ view: AttachmentHoverTrackingView, context: Context) { view.hover = hover }
    static func dismantleNSView(_ view: AttachmentHoverTrackingView, coordinator: ()) { view.stop() }
}

final class AttachmentHoverTrackingView: NSView {
    var hover: ((CGPoint?) -> Void)?
    private var area: NSTrackingArea?
    private var active = false
    private var monitor: Any?
    private var blurObserver: NSObjectProtocol?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let blurObserver { NotificationCenter.default.removeObserver(blurObserver) }
    }
    func stop() { if active { active = false; hover?(nil) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let blurObserver { NotificationCenter.default.removeObserver(blurObserver); self.blurObserver = nil }
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited, .scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
               self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) {
                self.active = true; self.hover?(event.locationInWindow)
            } else { self.stop() }
            return event
        }
        blurObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.stop() }
    }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); self.area = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { active = true; hover?(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { active = true; hover?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { stop() }
}

enum AttachmentHoverPlacement {
    static func frame(cursor: CGPoint, size: CGSize, bounds: CGRect) -> CGRect {
        var x = cursor.x + 18, y = cursor.y + 18
        if x + size.width > bounds.maxX - 8 { x = cursor.x - size.width - 18 }
        if y + size.height > bounds.maxY - 8 { y = cursor.y - size.height - 18 }
        return CGRect(x: max(bounds.minX + 8, min(x, bounds.maxX - size.width - 8)),
                      y: max(bounds.minY + 8, min(y, bounds.maxY - size.height - 8)), width: size.width, height: size.height)
    }
}

struct AttachmentHoverPreviewLayer: View {
    @ObservedObject var session: AttachmentHoverSession
    var body: some View {
        AttachmentHoverCanvas(request: session.visible ? session.request : nil, image: session.image, error: session.error)
    }
}

private struct AttachmentHoverCanvas: NSViewRepresentable {
    var request: AttachmentHoverRequest?
    var image: NSImage?
    var error: String?
    func makeNSView(context: Context) -> AttachmentHoverCanvasView { AttachmentHoverCanvasView() }
    func updateNSView(_ view: AttachmentHoverCanvasView, context: Context) {
        view.request = request; view.image = image; view.error = error; view.needsDisplay = true
    }
}

final class AttachmentHoverCanvasView: NSView {
    var request: AttachmentHoverRequest?
    var image: NSImage?
    var error: String?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var cardFrame: CGRect? {
        guard let request else { return nil }
        let width = min(320, max(160, bounds.width - 16))
        let imageHeight = image.map { min(300, max(100, (width - 24) * $0.size.height / max(1, $0.size.width))) } ?? 100
        let height = min(bounds.height - 16, imageHeight + 72)
        return AttachmentHoverPlacement.frame(cursor: convert(request.location, from: nil), size: CGSize(width: width, height: height), bounds: bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let request, let card = cardFrame else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
        NSColor.white.setFill(); NSBezierPath(roundedRect: card, xRadius: 11, yRadius: 11).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.10).setStroke(); NSBezierPath(roundedRect: card, xRadius: 11, yRadius: 11).stroke()
        let title = NSMutableParagraphStyle(); title.lineBreakMode = .byTruncatingMiddle
        (request.attachment.name as NSString).draw(in: CGRect(x: card.minX + 12, y: card.minY + 11, width: card.width - 24, height: 20),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: title])
        let target = CGRect(x: card.minX + 12, y: card.minY + 38, width: card.width - 24, height: card.height - 72)
        NSColor(white: 0.97, alpha: 1).setFill(); NSBezierPath(roundedRect: target, xRadius: 5, yRadius: 5).fill()
        if let image {
            let scale = min(target.width / max(1, image.size.width), target.height / max(1, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            ((error ?? "正在预览…") as NSString).draw(in: target.insetBy(dx: 12, dy: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        }
        let hint = request.url.pathExtension.lowercased() == "pdf" ? "第 1 页 · 点击文件图标打开" : "点击文件图标打开"
        (hint as NSString).draw(at: NSPoint(x: card.minX + 12, y: card.maxY - 24), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
    }
}
