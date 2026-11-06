import SwiftUI
import AppKit
import PDFKit

struct FormPreviewCommand {
    enum Action { case fit, zoomIn, zoomOut }
    let id = UUID()
    var action: Action
}

enum TripFormPDF {
    static func document(_ data: TripFormData) -> PDFDocument? {
        let paper = TripFormPaper(data: data)
        var bounds = CGRect(x: 0, y: 0, width: TripFormPaper.width, height: TripFormPaper.height(for: data))
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(bounds)
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for cell in paper.cells {
            if cell.border {
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
                context.setLineWidth(0.7); context.stroke(cell.rect)
            }
            guard !cell.text.isEmpty else { continue }
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
            var size = cell.size
            func attributes() -> [NSAttributedString.Key: Any] {
                var font = NSFont(name: "Songti SC", size: size) ?? NSFont.systemFont(ofSize: size)
                if cell.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                return [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
            }
            let width = max(1, cell.rect.width - 8)
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            var text = NSAttributedString(string: cell.text, attributes: attributes())
            var measured = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: options)
            while measured.height > cell.rect.height - 4 && size > cell.size * 0.65 {
                size -= 0.5
                text = NSAttributedString(string: cell.text, attributes: attributes())
                measured = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: options)
            }
            let height = min(cell.rect.height - 4, ceil(measured.height))
            text.draw(with: CGRect(x: cell.rect.minX + 4, y: cell.rect.midY - height / 2, width: width, height: height), options: options)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        return PDFDocument(data: bytes as Data)
    }
}

struct InteractiveTripForm: NSViewRepresentable {
    var data: TripFormData
    var command: FormPreviewCommand
    var close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> FormPDFView { FormPDFView() }
    func updateNSView(_ view: FormPDFView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.claim != data.claim || coordinator.personID != data.person?.id {
            coordinator.claim = data.claim; coordinator.personID = data.person?.id
            view.document = TripFormPDF.document(data)
            view.fitDocument()
        }
        if coordinator.commandID != command.id {
            coordinator.commandID = command.id
            switch command.action {
            case .fit: view.fitDocument()
            case .zoomIn: view.zoom(by: 1.25, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            case .zoomOut: view.zoom(by: 0.8, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            }
        }
        view.closeAction = close
    }
    final class Coordinator {
        var claim: Claim?
        var personID: String?
        var commandID: UUID?
    }
}

final class FormPDFView: PreviewCanvasView {
    var document: PDFDocument? { didSet { currentSelection = nil; fitDocument() } }
    var closeAction: (() -> Void)?
    private(set) var currentSelection: PDFSelection?
    private(set) var zoomFactor: CGFloat = 1
    private(set) var pan = CGPoint.zero
    private var lastPanPoint: CGPoint?
    private var selectionStart: CGPoint?
    private var spaceDown = false
    private var page: PDFPage? { document?.page(at: 0) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var pageBounds: CGRect { page?.bounds(for: .mediaBox) ?? .zero }
    private var fitScale: CGFloat { max(0.001, min(max(1, bounds.width - 32) / max(1, pageBounds.width), max(1, bounds.height - 32) / max(1, pageBounds.height))) }
    var scaleFactor: CGFloat { fitScale * zoomFactor }
    var pageRect: CGRect {
        let size = CGSize(width: pageBounds.width * scaleFactor, height: pageBounds.height * scaleFactor)
        return CGRect(x: bounds.midX + pan.x - size.width / 2, y: bounds.midY + pan.y - size.height / 2, width: size.width, height: size.height)
    }
    func convert(_ point: CGPoint, from page: PDFPage) -> CGPoint {
        CGPoint(x: pageRect.minX + (point.x - pageBounds.minX) * scaleFactor, y: pageRect.minY + (point.y - pageBounds.minY) * scaleFactor)
    }
    func convert(_ point: CGPoint, to page: PDFPage) -> CGPoint {
        CGPoint(x: (point.x - pageRect.minX) / scaleFactor + pageBounds.minX, y: (point.y - pageRect.minY) / scaleFactor + pageBounds.minY)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.93, green: 0.95, blue: 0.97, alpha: 1).setFill(); bounds.fill()
        guard let page, let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12); shadow.shadowBlurRadius = 7; shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.set()
        NSColor.white.setFill(); pageRect.fill()
        NSGraphicsContext.restoreGraphicsState()
        context.saveGState()
        context.translateBy(x: pageRect.minX, y: pageRect.minY)
        context.scaleBy(x: scaleFactor, y: scaleFactor)
        context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
        page.draw(with: .mediaBox, to: context)
        if let selection = currentSelection {
            context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.32).cgColor)
            for line in selection.selectionsByLine() { context.fill(line.bounds(for: page)) }
        }
        context.restoreGState()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); clampPan(); needsDisplay = true }
    func fitDocument() { zoomFactor = 1; pan = .zero; needsDisplay = true }
    func zoom(by factor: CGFloat, around point: CGPoint) {
        let old = zoomFactor
        zoomFactor = max(0.25, min(8, zoomFactor * factor))
        let relative = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
        pan = CGPoint(x: relative.x - (relative.x - pan.x) * zoomFactor / old, y: relative.y - (relative.y - pan.y) * zoomFactor / old)
        clampPan(); needsDisplay = true
    }
    private func clampPan() {
        let x = max(0, (pageRect.width - bounds.width) / 2 + 16), y = max(0, (pageRect.height - bounds.height) / 2 + 16)
        pan = CGPoint(x: min(x, max(-x, pan.x)), y: min(y, max(-y, pan.y)))
    }
    override func scrollWheel(with event: NSEvent) {
        zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.012 : 0.08)), around: convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) { zoom(by: max(0.1, 1 + event.magnification), around: convert(event.locationInWindow, from: nil)) }
    private func isText(_ point: CGPoint, page: PDFPage) -> Bool {
        let index = page.characterIndex(at: point)
        return index >= 0 && index < page.numberOfCharacters && page.characterBounds(at: index).insetBy(dx: -2, dy: -2).contains(point)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let page else { return }
        let point = convert(event.locationInWindow, from: nil), pdfPoint = convert(point, to: page)
        if !spaceDown && !event.modifierFlags.contains(.option) && isText(pdfPoint, page: page) {
            if event.clickCount >= 2 { currentSelection = page.selectionForWord(at: pdfPoint); selectionStart = nil }
            else { currentSelection = nil; selectionStart = pdfPoint }
        } else if event.clickCount == 2 {
            fitDocument(); selectionStart = nil; lastPanPoint = nil
        } else { lastPanPoint = point; selectionStart = nil; NSCursor.closedHand.set() }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = selectionStart, let page { currentSelection = page.selection(from: start, to: convert(point, to: page)); needsDisplay = true }
        else if let last = lastPanPoint {
            pan.x += point.x - last.x; pan.y += point.y - last.y; clampPan(); needsDisplay = true; lastPanPoint = point
        }
    }
    override func mouseUp(with event: NSEvent) { selectionStart = nil; lastPanPoint = nil; NSCursor.arrow.set() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = true; return }
        if event.keyCode == 53 { closeAction?(); return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { spaceDown = false; lastPanPoint = nil; return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copy(nil); return true
        case "a": selectAll(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
    @objc func copy(_ sender: Any?) {
        guard let text = currentSelection?.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    override func selectAll(_ sender: Any?) { currentSelection = document?.selectionForEntireDocument; needsDisplay = true }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(); menu.autoenablesItems = false
        let copy = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: ""); copy.target = self; copy.isEnabled = !(currentSelection?.string ?? "").isEmpty; menu.addItem(copy)
        let all = NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: ""); all.target = self; menu.addItem(all)
        return menu
    }
}
