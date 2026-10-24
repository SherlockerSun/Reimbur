import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PreviewItem: Identifiable {
    let attachment: Attachment
    let url: URL
    var id: UUID { attachment.id }
}

struct PreviewRequest: Identifiable {
    let items: [PreviewItem]
    let initialIndex: Int
    var attachment: Attachment { items[initialIndex].attachment }
    var url: URL { items[initialIndex].url }
    var id: UUID { attachment.id }

    init(attachment: Attachment, url: URL) {
        items = [PreviewItem(attachment: attachment, url: url)]
        initialIndex = 0
    }
    init(attachments: [Attachment], selected: Attachment, attachmentRoot: URL) {
        let attachments = attachments.contains(where: { $0.id == selected.id }) ? attachments : [selected]
        items = attachments.map { PreviewItem(attachment: $0, url: attachmentRoot.appendingPathComponent($0.storedName)) }
        initialIndex = attachments.firstIndex(where: { $0.id == selected.id }) ?? 0
    }
}

@MainActor final class AttachmentPreviewSession: ObservableObject {
    private var document: PDFDocument?
    @Published private(set) var image: NSImage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pageNumber = 1
    @Published private(set) var itemIndex: Int
    private let items: [PreviewItem]
    private var cachedPages: [Int: NSImage] = [:]
    var item: PreviewItem { items[itemIndex] }
    var itemCount: Int { items.count }
    var pageCount: Int { document?.pageCount ?? 0 }
    var isPDF: Bool { document != nil }
    var canMovePrevious: Bool { pageNumber > 1 || itemIndex > 0 }
    var canMoveNext: Bool { pageNumber < pageCount || itemIndex + 1 < itemCount }
    var contentID: String { "\(item.id)-\(pageNumber)" }
    var position: String {
        let file = "\(itemIndex + 1) / \(itemCount)"
        return isPDF ? "\(file) · 第 \(pageNumber) / \(pageCount) 页" : file
    }

    convenience init(url: URL) {
        self.init(request: PreviewRequest(attachment: Attachment(name: url.lastPathComponent, storedName: url.lastPathComponent), url: url))
    }
    init(request: PreviewRequest) {
        items = request.items
        itemIndex = request.initialIndex
        load()
    }
    private func load() {
        document = nil; image = nil; errorMessage = nil; pageNumber = 1; cachedPages = [:]
        let url = item.url
        if url.pathExtension.lowercased() == "pdf" {
            if let loaded = PDFDocument(url: url), !loaded.isLocked, loaded.pageCount > 0,
               let page = loaded.page(at: 0), let rendered = Self.render(page) {
                document = loaded; image = rendered; cachedPages[0] = rendered
            } else { errorMessage = "无法读取 PDF，文件可能已丢失、损坏或加密。" }
        } else if let loaded = NSImage(contentsOf: url), loaded.isValid {
            image = loaded
        } else { errorMessage = "无法读取图片，文件可能已丢失或损坏。" }
    }
    private static func render(_ page: PDFPage) -> NSImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(3, 3000 / max(bounds.width, bounds.height))
        return page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
    }
    func movePage(_ delta: Int) {
        let index = pageNumber - 1 + delta
        guard let document, index >= 0, index < document.pageCount,
              let page = document.page(at: index), let rendered = cachedPages[index] ?? Self.render(page) else { return }
        cachedPages[index] = rendered
        cachedPages = cachedPages.filter { abs($0.key - index) <= 1 }
        image = rendered; pageNumber = index + 1
    }
    func move(_ delta: Int) {
        guard delta == -1 || delta == 1 else { return }
        if (delta < 0 && pageNumber > 1) || (delta > 0 && pageNumber < pageCount) {
            movePage(delta)
        } else if items.indices.contains(itemIndex + delta) {
            itemIndex += delta
            load()
            if delta < 0 && pageCount > 1 { movePage(pageCount - 1) }
        }
    }
    @discardableResult func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard FileManager.default.fileExists(atPath: item.url.path) else { return false }
        var objects: [NSPasteboardWriting] = [item.url as NSURL]
        if let image { objects.append(image) }
        pasteboard.clearContents()
        return pasteboard.writeObjects(objects)
    }
    func saveCopy(to destination: URL) throws {
        guard item.url.standardizedFileURL != destination.standardizedFileURL else { return }
        try Data(contentsOf: item.url).write(to: destination, options: .atomic)
    }
}

struct PreviewIconButton: View {
    var title: String
    var icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 30, height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

struct AttachmentPreview: View {
    let request: PreviewRequest
    var close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: AttachmentPreviewSession
    @State private var copied = false
    @State private var actionError: String?

    init(request: PreviewRequest, close: (() -> Void)? = nil) {
        self.close = close
        self.request = request
        _session = StateObject(wrappedValue: AttachmentPreviewSession(request: request))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: session.isPDF ? "doc.richtext" : "photo").foregroundStyle(Palette.accent)
                Text(session.item.attachment.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                PreviewIconButton(title: "上一张", icon: "chevron.left") { session.move(-1) }.disabled(!session.canMovePrevious)
                Text(session.position).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                PreviewIconButton(title: "下一张", icon: "chevron.right") { session.move(1) }.disabled(!session.canMoveNext)
                Divider().frame(height: 18)
                PreviewIconButton(title: copied ? "已复制" : "复制", icon: copied ? "checkmark" : "doc.on.doc", action: copy)
                PreviewIconButton(title: "下载", icon: "arrow.down.to.line", action: download)
            }.padding(16).background(.white)
            Divider()
            ZStack {
                if let error = session.errorMessage {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.doc").font(.largeTitle)
                        Text(error)
                    }.foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = session.image {
                    InteractiveAttachmentCanvas(image: image, contentID: session.contentID, copy: copy, download: download,
                                                previous: { session.move(-1) }, next: { session.move(1) }, close: dismissPreview)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    HStack {
                        edgeButton(previous: true)
                        Spacer()
                        edgeButton(previous: false)
                    }.padding(.horizontal, 12)
                }
        }.background(Palette.canvas)
            .onChange(of: session.contentID) { _, _ in copied = false }
            .onExitCommand(perform: dismissPreview)
            .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("知道了") { actionError = nil }
            } message: { Text(actionError ?? "") }
    }
    private func edgeButton(previous: Bool) -> some View {
        Button { session.move(previous ? -1 : 1) } label: {
            Image(systemName: previous ? "chevron.left" : "chevron.right")
                .font(.system(size: 18, weight: .semibold)).frame(width: 36, height: 52)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(previous ? !session.canMovePrevious : !session.canMoveNext)
            .opacity((previous ? session.canMovePrevious : session.canMoveNext) ? 1 : 0.25)
            .help(previous ? "上一张" : "下一张").accessibilityLabel(previous ? "上一张（左侧）" : "下一张（右侧）")
    }
    private func copy() {
        copied = session.copy()
        if !copied { actionError = "附件已丢失，无法复制。" }
    }
    private func download() {
        let panel = NSSavePanel()
        panel.title = "下载附件"
        panel.nameFieldStringValue = session.item.attachment.name
        if let type = UTType(filenameExtension: session.item.url.pathExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try session.saveCopy(to: destination) } catch { actionError = error.localizedDescription }
    }
    private func dismissPreview() { if let close { close() } else { dismiss() } }
}

struct InteractiveAttachmentCanvas: NSViewRepresentable {
    var image: NSImage
    var contentID: String
    var copy: () -> Void
    var download: () -> Void
    var previous: () -> Void
    var next: () -> Void
    var close: () -> Void
    func makeNSView(context: Context) -> AttachmentCanvasView { AttachmentCanvasView() }
    func updateNSView(_ view: AttachmentCanvasView, context: Context) {
        view.setImage(image, contentID: contentID)
        view.copyAction = copy; view.downloadAction = download
        view.previousAction = previous; view.nextAction = next; view.closeAction = close
    }
}

final class AttachmentCanvasView: NSView {
    private var image: NSImage?
    private(set) var contentID = ""
    private var lastDragPoint: CGPoint?
    private(set) var zoom: CGFloat = 1
    private(set) var pan = CGPoint.zero
    var copyAction: (() -> Void)?
    var downloadAction: (() -> Void)?
    var previousAction: (() -> Void)?
    var nextAction: (() -> Void)?
    var closeAction: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setImage(_ image: NSImage, contentID: String) {
        self.image = image
        if self.contentID != contentID { self.contentID = contentID; fit() }
        needsDisplay = true
    }
    private var fitScale: CGFloat {
        guard let image else { return 1 }
        return max(0.001, min(max(1, bounds.width - 48) / max(1, image.size.width), max(1, bounds.height - 48) / max(1, image.size.height)))
    }
    var imageRect: CGRect {
        guard let image else { return .zero }
        let size = CGSize(width: image.size.width * fitScale * zoom, height: image.size.height * fitScale * zoom)
        return CGRect(x: bounds.midX + pan.x - size.width / 2, y: bounds.midY + pan.y - size.height / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
        bounds.fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampPan(); needsDisplay = true
    }
    func fit() { zoom = 1; pan = .zero; needsDisplay = true }
    private func clampPan() {
        let rect = imageRect
        let maxX = max(0, (rect.width - bounds.width) / 2 + 24)
        let maxY = max(0, (rect.height - bounds.height) / 2 + 24)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
    }
    func zoom(by factor: CGFloat, around point: CGPoint) {
        let old = zoom
        zoom = min(8, max(0.25, zoom * factor))
        let relative = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        pan = CGPoint(x: relative.x - (relative.x - pan.x) * zoom / old,
                      y: relative.y - (relative.y - pan.y) * zoom / old)
        clampPan(); needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.012 : 0.08)), around: convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) {
        zoom(by: max(0.1, 1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { fit(); lastDragPoint = nil; return }
        lastDragPoint = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let last = lastDragPoint {
            pan.x += point.x - last.x; pan.y += point.y - last.y
            clampPan(); needsDisplay = true
        }
        lastDragPoint = point
    }
    override func mouseUp(with event: NSEvent) { lastDragPoint = nil; NSCursor.openHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: previousAction?()
        case 124: nextAction?()
        case 53: closeAction?()
        default: super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, symbol, action) in [("复制", "doc.on.doc", #selector(copyAttachment)), ("下载", "arrow.down.to.line", #selector(downloadAttachment))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            menu.addItem(item)
        }
        return menu
    }
    @objc private func copyAttachment() { copyAction?() }
    @objc private func downloadAttachment() { downloadAction?() }
}
