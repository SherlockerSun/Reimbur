import SwiftUI
import AppKit
import PDFKit

struct ReimbursementFormData: Equatable {
    var claim: Claim
    var date: String {
        let key = claim.reimbursementDates.sorted().last ?? DayKey.string(claim.updatedAt)
        let parts = key.split(separator: "-")
        return parts.count == 3 ? "\(parts[0])年\(parts[1])月\(parts[2])日" : key
    }
    var purpose: String { claim.ledgerPurpose }
    var total: Int64 { claim.total }
    var claimant: String {
        var names = claim.travelerNames ?? []
        for name in claim.expenses.compactMap(\.claimant) where !names.contains(name) { names.append(name) }
        return names.joined(separator: "、")
    }
}

struct ReimbursementFormPreview: View {
    var claim: Claim
    var close: () -> Void = {}
    @State private var command = FormPreviewCommand(action: .fit)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("报销单预览").font(.system(size: 19, weight: .semibold))
                Spacer()
                PreviewIconButton(title: "缩小", icon: "minus.magnifyingglass") { command = FormPreviewCommand(action: .zoomOut) }
                PreviewIconButton(title: "放大", icon: "plus.magnifyingglass") { command = FormPreviewCommand(action: .zoomIn) }
                PreviewIconButton(title: "适应窗口", icon: "arrow.down.right.and.arrow.up.left") { command = FormPreviewCommand(action: .fit) }
            }.padding(.trailing, 38)
            InteractiveReimbursementForm(data: ReimbursementFormData(claim: claim), command: command, close: close)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text("滚轮缩放 · 拖动空白处或按住空格平移 · 拖选文字后 ⌘C 复制")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(22)
    }
}

struct ReimbursementFormPaper: View {
    static let width: CGFloat = 1100
    static let paperHeight: CGFloat = 570
    var data: ReimbursementFormData
    struct Cell: Identifiable { var id: Int; var rect: CGRect; var text: String; var size: CGFloat = 18; var border = true; var bold = false }

    var cells: [Cell] {
        var cells: [Cell] = []
        let left: CGFloat = 38, width = Self.width - 76
        func cell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ text: String, size: CGFloat = 18, border: Bool = true, bold: Bool = false) {
            cells.append(Cell(id: cells.count, rect: CGRect(x: x, y: y, width: w, height: h), text: text, size: size, border: border, bold: bold))
        }
        cell(left, 24, width, 58, "原 始 凭 证 粘 贴 单", size: 34, border: false, bold: true)
        cell(left, 92, width, 32, "年    月    日：" + data.date, size: 17, border: false)
        let tableTop: CGFloat = 138
        let purposeWidth: CGFloat = 180, mainWidth = width - purposeWidth
        cell(left, tableTop, mainWidth, 270, "凭证粘贴处", size: 22)
        cell(left + mainWidth, tableTop, purposeWidth, 55, "用途", size: 18)
        cell(left + mainWidth, tableTop + 55, purposeWidth, 215, data.purpose, size: 20)
        cell(left, tableTop + 270, 150, 86, "合计人民币\n（大写）", size: 18)
        cell(left + 150, tableTop + 270, width - 150, 86, ChineseMoney.uppercase(data.total), size: 24)
        cell(left, tableTop + 356, width, 70, "制单及领款人：" + data.claimant, size: 19)
        return cells
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(cells) { cell in
                Text(cell.text).font(.custom("Songti SC", size: cell.size).weight(cell.bold ? .semibold : .regular))
                    .foregroundStyle(.black).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.65)
                    .padding(.horizontal, 5).frame(width: cell.rect.width, height: cell.rect.height)
                    .overlay { if cell.border { Rectangle().stroke(.black.opacity(0.85), lineWidth: 0.8) } }
                    .position(x: cell.rect.midX, y: cell.rect.midY)
            }
        }.frame(width: Self.width, height: Self.paperHeight)
    }
}

enum ReimbursementFormPDF {
    static func document(_ data: ReimbursementFormData) -> PDFDocument? {
        let paper = ReimbursementFormPaper(data: data)
        var bounds = CGRect(x: 0, y: 0, width: ReimbursementFormPaper.width, height: ReimbursementFormPaper.paperHeight)
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(bounds)
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for cell in paper.cells {
            if cell.border { context.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor); context.setLineWidth(0.8); context.stroke(cell.rect) }
            guard !cell.text.isEmpty else { continue }
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
            var size = cell.size
            func attributed() -> NSAttributedString {
                var font = NSFont(name: "Songti SC", size: size) ?? NSFont.systemFont(ofSize: size)
                if cell.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                return NSAttributedString(string: cell.text, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
            }
            let drawing: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            let available = max(1, cell.rect.width - 10)
            var text = attributed(); var measured = text.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude), options: drawing)
            while measured.height > cell.rect.height - 6 && size > cell.size * 0.65 { size -= 0.5; text = attributed(); measured = text.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude), options: drawing) }
            let height = min(cell.rect.height - 6, ceil(measured.height))
            text.draw(with: CGRect(x: cell.rect.minX + 5, y: cell.rect.midY - height / 2, width: available, height: height), options: drawing)
        }
        NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
        return PDFDocument(data: bytes as Data)
    }
}

struct InteractiveReimbursementForm: NSViewRepresentable {
    var data: ReimbursementFormData
    var command: FormPreviewCommand
    var close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> FormPDFView { FormPDFView() }
    func updateNSView(_ view: FormPDFView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.claim != data.claim {
            coordinator.claim = data.claim
            view.document = ReimbursementFormPDF.document(data)
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
    final class Coordinator { var claim: Claim?; var commandID: UUID? }
}
