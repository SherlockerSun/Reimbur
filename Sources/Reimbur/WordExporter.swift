import AppKit
import PDFKit

enum WordExporter {
    private struct Picture { var filename: String; var width: Int; var height: Int; var title: String }

    static func export(claims: [Claim], attachmentRoot: URL, to destination: URL, packLandscapeInvoices: Bool = true) throws {
        guard !claims.isEmpty else { throw ReimburError("请先创建报销记录。") }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Reimbur-export-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let package = staging.appendingPathComponent("document")
        for path in ["_rels", "word/_rels", "word/media"] {
            try fm.createDirectory(at: package.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        var pictures: [Picture] = []
        var body = ""
        func paragraph(_ text: String, style: String? = nil) -> String {
            let properties = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
            return "<w:p>\(properties)<w:r><w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r></w:p>"
        }
        func pageBreak() { if !body.isEmpty { body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" } }
        func addImage(_ image: NSImage, title: String, newPage: Bool = true, maxHeight: Double = 10.25) throws {
            let index = pictures.count + 1
            let filename = "image\(index).jpg"
            let picture = try rasterize(image, filename: filename, title: title,
                                        destination: package.appendingPathComponent("word/media/\(filename)"))
            pictures.append(picture)
            if newPage { pageBreak() }
            body += paragraph(title, style: "Caption")
            let scale = min(7.72 * 914400 / Double(picture.width), maxHeight * 914400 / Double(picture.height))
            let cx = Int(Double(picture.width) * scale), cy = Int(Double(picture.height) * scale)
            body += """
            <w:p><w:pPr><w:jc w:val="center"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:drawing>
            <wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(index)" name="\(xml(title))" descr="\(xml(title))"/>
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>
            <pic:nvPicPr><pic:cNvPr id="\(index)" name="\(filename)"/><pic:cNvPicPr/></pic:nvPicPr>
            <pic:blipFill><a:blip r:embed="rIdImage\(index)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
        }
        for source in claims {
            let claim = source.withPeopleAssigned
            pageBreak()
            body += paragraph(claim.title, style: "Title")
            body += paragraph("\(claim.kind.rawValue)报销　\(claim.dateSummary)")
            if !(claim.travelerNames ?? []).isEmpty || claim.kind == .trip {
                body += paragraph("\(claim.kind == .trip ? "出差人" : "报销人")：\((claim.travelerNames ?? []).joined(separator: "、"))　共 \(claim.travelerCount) 人")
            }
            body += paragraph("报销总额：\(Money.format(claim.total))　发票：\(claim.invoiceCount) 份　发票金额：\(Money.format(claim.invoiceTotal))")
            body += paragraph("差额（报销总额 − 发票金额）：\(Money.format(claim.difference))")
            if !claim.note.isEmpty { body += paragraph("备注：\(claim.note)") }
            let widths = [1400, 4600, 1700, 2000]
            func row(_ cells: [String], header: Bool) -> String {
                "<w:tr>\(header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")" + zip(cells, widths).map { text, width in
                    "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/><w:vAlign w:val=\"center\"/>\(header ? "<w:shd w:fill=\"E8EEF2\"/>" : "")</w:tcPr>\(paragraph(text))</w:tc>"
                }.joined() + "</w:tr>"
            }
            body += """
            <w:tbl><w:tblPr><w:tblW w:w="9700" w:type="dxa"/><w:tblLayout w:type="fixed"/>
            <w:tblBorders><w:top w:val="single" w:sz="4" w:color="D9D9D9"/><w:left w:val="single" w:sz="4" w:color="D9D9D9"/><w:bottom w:val="single" w:sz="4" w:color="D9D9D9"/><w:right w:val="single" w:sz="4" w:color="D9D9D9"/><w:insideH w:val="single" w:sz="4" w:color="D9D9D9"/><w:insideV w:val="single" w:sz="4" w:color="D9D9D9"/></w:tblBorders>
            <w:tblCellMar><w:top w:w="100" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr>
            <w:tblGrid>\(widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined())</w:tblGrid>
            """
            body += row(["费用项目", "报销人、计算方式及行程", "金额", "发票"], header: true)
            for expense in claim.expenses {
                let route = expense.kind.hasRoute ? "\(expense.origin) → \(expense.destination)\n" : ""
                let owner = expense.claimant.map { "报销人：\($0)\n" } ?? ""
                body += row([expense.kind.rawValue, owner + route + expense.formula(in: claim), Money.format(expense.total(in: claim)), "\(expense.invoices.count) 份 / \(Money.format(expense.invoiceTotal))"], header: false)
            }
            body += "</w:tbl>"
            if claim.personBreakdowns.contains(where: { $0.claimant != nil }) {
                body += paragraph("个人汇总")
                for person in claim.personBreakdowns {
                    body += paragraph("\(person.name)：报销 \(Money.format(person.total(in: claim)))　发票 \(person.invoiceCount) 份　票面 \(Money.format(person.invoiceTotal))")
                }
            }
            body += paragraph("发票数量仅计发票 PDF；行程单不参与统计。每份 PDF 的全部页面均附在后面。")
            for cover in claim.covers {
                try autoreleasepool {
                    guard let image = NSImage(contentsOf: attachmentRoot.appendingPathComponent(cover.storedName)) else {
                        throw ReimburError("报销单图片丢失或损坏：\(cover.name)")
                    }
                    try addImage(image, title: "\(claim.title) · 报销单 · \(cover.name)")
                }
            }
            var halfPageUsed = false
            for expense in claim.expenses {
                for invoice in expense.attachments {
                    if attachmentRoot.appendingPathComponent(invoice.storedName).pathExtension.lowercased() != "pdf" {
                        guard let image = NSImage(contentsOf: attachmentRoot.appendingPathComponent(invoice.storedName)), image.isValid else {
                            throw ReimburError("行程单图片丢失或损坏：\(invoice.name)")
                        }
                        try addImage(image, title: "\(expense.kind.rawValue) · 行程单 · \(invoice.name)")
                        halfPageUsed = false
                        continue
                    }
                    guard let pdf = PDFDocument(url: attachmentRoot.appendingPathComponent(invoice.storedName)), !pdf.isLocked, pdf.pageCount > 0 else {
                        throw ReimburError("发票文件丢失、损坏或已加密：\(invoice.name)")
                    }
                    for index in 0..<pdf.pageCount {
                        try autoreleasepool {
                            guard let page = pdf.page(at: index) else { throw ReimburError("无法读取 \(invoice.name) 第 \(index + 1) 页。") }
                            let bounds = page.bounds(for: .mediaBox)
                            guard bounds.width > 0, bounds.height > 0 else { throw ReimburError("PDF 页面尺寸无效。") }
                            let scale = min(2.5, 2600 / max(bounds.width, bounds.height))
                            let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                            let landscape = packLandscapeInvoices && image.size.height / image.size.width <= 0.78
                            let role = expense.invoices.contains(where: { $0.id == invoice.id }) ? "发票" : "行程单"
                            try addImage(image, title: "\(expense.kind.rawValue)\(expense.claimant.map { " · \($0)" } ?? "") · \(role) · \(invoice.name) · 第 \(index + 1)/\(pdf.pageCount) 页",
                                         newPage: !landscape || !halfPageUsed, maxHeight: landscape ? 4.95 : 10.25)
                            halfPageUsed = landscape ? !halfPageUsed : false
                        }
                    }
                }
            }
        }
        body += "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"360\" w:right=\"360\" w:bottom=\"360\" w:left=\"360\" w:header=\"0\" w:footer=\"0\"/></w:sectPr>"
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="PingFang SC"/><w:color w:val="000000"/><w:sz w:val="20"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:color w:val="000000"/><w:sz w:val="36"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="Caption"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="40" w:after="60"/></w:pPr><w:rPr><w:sz w:val="18"/></w:rPr></w:style>
        </w:styles>
        """
        let relationships = """
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\(pictures.enumerated().map { i, p in "<Relationship Id=\"rIdImage\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(p.filename)\"/>" }.joined())</Relationships>
        """
        let types = """
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        for (path, text) in ["word/document.xml": document, "word/styles.xml": styles, "word/_rels/document.xml.rels": relationships, "[Content_Types].xml": types,
                             "_rels/.rels": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"] {
            try text.write(to: package.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let archive = staging.appendingPathComponent("output.docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = package
        process.arguments = ["-q", "-r", archive.path, "."]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReimburError("Word 文档打包失败，原有导出文件未被覆盖。") }
        try Data(contentsOf: archive, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }

    private static func rasterize(_ image: NSImage, filename: String, title: String, destination: URL) throws -> Picture {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw ReimburError("无法转换图片：\(title)") }
        let scale = min(1, 2600 / Double(max(source.width, source.height)))
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ReimburError("图片转换内存不足。") }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage(), let data = NSBitmapImageRep(cgImage: rendered).representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { throw ReimburError("无法编码打印图片。") }
        try data.write(to: destination)
        return Picture(filename: filename, width: width, height: height, title: title)
    }

    private static func xml(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 })
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
