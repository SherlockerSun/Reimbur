import AppKit
import PDFKit

enum WordExporter {
    private struct Picture { var filename: String; var width: Int; var height: Int; var title: String }

    static func export(claims: [Claim], attachmentRoot: URL, to destination: URL) throws {
        guard !claims.isEmpty else { throw ReimburError("请先创建报销记录。") }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Reimbur-export-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let package = staging.appendingPathComponent("document")
        for path in ["_rels", "word/_rels", "word/media"] {
            try fm.createDirectory(at: package.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        var pictures: [Picture] = []
        var placements: [Int] = []
        func addImage(_ image: NSImage, title: String, itinerary: Bool = false, copies: Int = 1) throws {
            let filename = "image\(pictures.count + 1).jpg"
            let picture = try rasterize(image, filename: filename, title: title, cropBottomWhitespace: itinerary,
                                        destination: package.appendingPathComponent("word/media/\(filename)"))
            pictures.append(picture)
            placements.append(contentsOf: Array(repeating: pictures.count - 1, count: copies))
        }
        for claim in claims {
            // Keep signed reimbursement forms before this record's invoices, without adding prose.
            for cover in claim.covers {
                try autoreleasepool {
                    guard let image = NSImage(contentsOf: attachmentRoot.appendingPathComponent(cover.storedName)), image.isValid else {
                        throw ReimburError("报销单图片丢失或损坏：\(cover.name)")
                    }
                    try addImage(image, title: "报销单 · \(cover.name)")
                }
            }
            for expense in claim.expenses {
                for attachment in expense.attachments {
                    let isInvoice = expense.invoices.contains { $0.id == attachment.id }
                    let role = isInvoice ? "发票" : "行程单"
                    let copies = isInvoice && expense.kind == .train ? 2 : 1
                    let url = attachmentRoot.appendingPathComponent(attachment.storedName)
                    if url.pathExtension.lowercased() != "pdf" {
                        try autoreleasepool {
                            guard let image = NSImage(contentsOf: url), image.isValid else {
                                throw ReimburError("\(role)图片丢失或损坏：\(attachment.name)")
                            }
                            try addImage(image, title: "\(expense.kind.rawValue) · \(role) · \(attachment.name)",
                                         itinerary: !isInvoice, copies: copies)
                        }
                        continue
                    }
                    guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
                        throw ReimburError("\(role)文件丢失、损坏或已加密：\(attachment.name)")
                    }
                    for index in 0..<pdf.pageCount {
                        try autoreleasepool {
                            guard let page = pdf.page(at: index) else { throw ReimburError("无法读取 \(attachment.name) 第 \(index + 1) 页。") }
                            let bounds = page.bounds(for: .mediaBox)
                            guard bounds.width > 0, bounds.height > 0 else { throw ReimburError("PDF 页面尺寸无效。") }
                            let scale = min(3.5, 2600 / max(bounds.width, bounds.height))
                            let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                            try addImage(image, title: "\(expense.kind.rawValue) · \(role) · \(attachment.name) · 第 \(index + 1)/\(pdf.pageCount) 页",
                                         itinerary: !isInvoice, copies: copies)
                        }
                    }
                }
            }
        }
        guard !placements.isEmpty else { throw ReimburError("没有可导出的附件，请先上传发票、行程单或报销单。") }

        // Fixed page-relative positions give every attachment the same half-page slot, regardless
        // of aspect ratio. A one-point paragraph owns each page; no captions or layout tables print.
        let pageWidth = 11906, pageHeight = 16838, margin = 284
        let slotHeight = (pageHeight - margin * 2) / 2
        var body = ""
        for pageStart in stride(from: 0, to: placements.count, by: 2) {
            body += "<w:p><w:pPr>\(pageStart > 0 ? "<w:pageBreakBefore/>" : "")<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/></w:pPr>"
            for slot in 0..<min(2, placements.count - pageStart) {
                let pictureIndex = placements[pageStart + slot]
                let picture = pictures[pictureIndex]
                let scale = min(Double((pageWidth - margin * 2) * 635) / Double(picture.width),
                                Double((slotHeight - 160) * 635) / Double(picture.height))
                let cx = Int(Double(picture.width) * scale), cy = Int(Double(picture.height) * scale)
                let x = (pageWidth * 635 - cx) / 2
                let y = (margin + slot * slotHeight) * 635 + (slotHeight * 635 - cy) / 2
                let drawingID = pageStart + slot + 1
                body += """
                <w:r><w:rPr><w:sz w:val="2"/></w:rPr><w:drawing>
                <wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="0" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">
                <wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>\(x)</wp:posOffset></wp:positionH><wp:positionV relativeFrom="page"><wp:posOffset>\(y)</wp:posOffset></wp:positionV>
                <wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/>
                <wp:docPr id="\(drawingID)" name="附件\(drawingID)" descr="\(xml(picture.title))"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>
                <pic:nvPicPr><pic:cNvPr id="\(drawingID)" name="\(picture.filename)"/><pic:cNvPicPr><a:picLocks noChangeAspect="1"/></pic:cNvPicPr></pic:nvPicPr>
                <pic:blipFill><a:blip r:embed="rIdImage\(pictureIndex + 1)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
                </pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>
                """
            }
            body += "</w:p>"
        }
        body += "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"284\" w:right=\"284\" w:bottom=\"284\" w:left=\"284\" w:header=\"0\" w:footer=\"0\"/></w:sectPr>"
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="2"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
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

    private static func rasterize(_ image: NSImage, filename: String, title: String, cropBottomWhitespace: Bool, destination: URL) throws -> Picture {
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
        guard let rendered = context.makeImage() else { throw ReimburError("无法转换打印图片。") }
        let trimmed = cropBottomWhitespace ? trimmingBottomWhitespace(rendered) : rendered
        guard let data = NSBitmapImageRep(cgImage: trimmed).representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { throw ReimburError("无法编码打印图片。") }
        try data.write(to: destination)
        return Picture(filename: filename, width: trimmed.width, height: trimmed.height, title: title)
    }

    /// Inspect the white-composited raster, not PDF text bounds: scanned receipts, logos, stamps
    /// and raster footers must all survive. Keep a small safety margin below the last ink pixel.
    private static func trimmingBottomWhitespace(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height, rowBytes = image.width * 4
        var pixels = [UInt8](repeating: 255, count: rowBytes * height)
        let lastInkRow: Int? = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.setFillColor(CGColor.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            for row in stride(from: height - 1, through: 0, by: -1) {
                for column in 0..<width {
                    let offset = row * rowBytes + column * 4
                    if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 245 { return row }
                }
            }
            return nil
        }
        guard let lastInkRow else { return image }
        let croppedHeight = min(height, lastInkRow + 1 + max(12, height / 100))
        guard height - croppedHeight > max(24, height / 50) else { return image }
        return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: croppedHeight)) ?? image
    }

    private static func xml(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 })
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
