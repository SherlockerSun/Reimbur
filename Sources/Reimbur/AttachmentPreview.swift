import SwiftUI
import AppKit
import PDFKit

struct PreviewRequest: Identifiable {
    let attachment: Attachment
    let url: URL
    var id: UUID { attachment.id }
}

@MainActor final class AttachmentPreviewSession: ObservableObject {
    private let document: PDFDocument?
    @Published private(set) var image: NSImage?
    let errorMessage: String?
    @Published private(set) var pageNumber = 1
    @Published private(set) var imageZoom: CGFloat = 1
    private var cachedPages: [Int: NSImage] = [:]
    var pageCount: Int { document?.pageCount ?? 0 }
    var isPDF: Bool { document != nil }

    init(url: URL) {
        if url.pathExtension.lowercased() == "pdf" {
            if let loaded = PDFDocument(url: url), !loaded.isLocked, loaded.pageCount > 0,
               let page = loaded.page(at: 0), let rendered = Self.render(page) {
                document = loaded
                image = rendered
                cachedPages[0] = rendered
                errorMessage = nil
            } else {
                document = nil
                image = nil
                errorMessage = "无法读取 PDF，文件可能已丢失、损坏或加密。"
            }
        } else if let loaded = NSImage(contentsOf: url), loaded.isValid {
            document = nil
            image = loaded
            errorMessage = nil
        } else {
            document = nil
            image = nil
            errorMessage = "无法读取图片，文件可能已丢失或损坏。"
        }
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
        // Keep only nearby pages, so large PDFs do not fill memory as users browse.
        cachedPages = cachedPages.filter { abs($0.key - index) <= 1 }
        image = rendered
        pageNumber = index + 1
        imageZoom = 1
    }
    func zoomIn() { imageZoom = min(4, imageZoom * 1.25) }
    func zoomOut() { imageZoom = max(0.25, imageZoom / 1.25) }
    func fit() { imageZoom = 1 }
}

struct AttachmentPreview: View {
    let request: PreviewRequest
    var close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: AttachmentPreviewSession

    init(request: PreviewRequest, close: (() -> Void)? = nil) {
        self.close = close
        self.request = request
        _session = StateObject(wrappedValue: AttachmentPreviewSession(url: request.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: session.isPDF ? "doc.richtext" : "photo").foregroundStyle(Palette.teal)
                Text(request.attachment.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                if session.errorMessage == nil {
                    if session.isPDF {
                        Button { session.movePage(-1) } label: { Image(systemName: "chevron.left") }.disabled(session.pageNumber <= 1).help("上一页")
                        Text("\(session.pageNumber) / \(session.pageCount)").font(.system(size: 12)).monospacedDigit()
                        Button { session.movePage(1) } label: { Image(systemName: "chevron.right") }.disabled(session.pageNumber >= session.pageCount).help("下一页")
                        Divider().frame(height: 20)
                    }
                    Button { session.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
                    Button("适应窗口") { session.fit() }
                    Button { session.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
                }
                Button("关闭") { if let close { close() } else { dismiss() } }.keyboardShortcut(.cancelAction)
            }.padding(16).background(.white)
            Divider()
            if let error = session.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.doc").font(.largeTitle).foregroundStyle(Palette.muted)
                    Text(error).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = session.image {
                GeometryReader { geometry in
                    let scale = min((geometry.size.width - 48) / max(1, image.size.width), (geometry.size.height - 48) / max(1, image.size.height))
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width * scale * session.imageZoom, height: image.size.height * scale * session.imageZoom)
                            .padding(24)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                }
            }
        }
        .background(Palette.canvas)
    }
}
