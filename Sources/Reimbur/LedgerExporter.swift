import Foundation

// The app writes standard XLSX files locally, without requiring Excel or a scripting runtime.
enum LedgerExporter {
    static let headers = ["序号", "日期", "姓名", "发票号码", "金额（元）", "报销单金额", "明细", "用途"]

    static func export(claim: Claim, to destination: URL) throws {
        guard claim.kind != .trip else { throw ReimburError("出差报销请使用打印文档导出。") }
        let claim = claim.withPeopleAssigned.withInvoiceLedger
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Reimbur-ledger-\(UUID())")
        defer { try? fm.removeItem(at: staging) }
        let package = staging.appendingPathComponent("workbook")
        for directory in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: package.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        func text(_ address: String, _ value: String, style: Int = 2) -> String {
            "<c r=\"\(address)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
        }
        func number(_ address: String, _ value: String, style: Int = 3) -> String {
            "<c r=\"\(address)\" s=\"\(style)\"><v>\(value)</v></c>"
        }
        let columns = ["A", "B", "C", "D", "E", "F", "G", "H"]
        var data = "<row r=\"1\" ht=\"26\" customHeight=\"1\">" + zip(columns, headers).map { text($0 + "1", $1, style: 1) }.joined() + "</row>"
        for (index, row) in claim.invoiceLedgerRows.enumerated() {
            let r = index + 2
            let lineCount = max(1, Int(ceil(Double(row.entry.detail.count) / 20)), Int(ceil(Double(row.purpose.count) / 16)))
            data += "<row r=\"\(r)\" ht=\"\(min(300, max(24, lineCount * 15 + 6)))\" customHeight=\"1\">"
            data += number("A\(r)", String(index + 1), style: 2)
            if let date = excelDate(row.entry.date) { data += number("B\(r)", String(date), style: 4) }
            else { data += text("B\(r)", row.entry.date) }
            data += text("C\(r)", row.entry.claimant ?? "")
            data += text("D\(r)", row.invoice?.number ?? "", style: 5)
            data += number("E\(r)", Money.input(row.invoice?.amount ?? 0))
            data += number("F\(r)", Money.input(row.entry.reimbursementAmount))
            data += text("G\(r)", row.entry.detail)
            data += text("H\(r)", row.purpose)
            data += "</row>"
        }
        let last = claim.invoiceLedgerRows.count + 1, total = last + 1
        data += "<row r=\"\(total)\" ht=\"26\" customHeight=\"1\">" + columns.map { column -> String in
            if column == "E" || column == "F" {
                let amount = column == "E" ? claim.invoiceTotal : claim.ledgerReimbursementTotal
                let formula = last >= 2 ? "SUM(\(column)2:\(column)\(last))" : "0"
                return "<c r=\"\(column)\(total)\" s=\"7\"><f>\(formula)</f><v>\(Money.input(amount))</v></c>"
            }
            return text(column + String(total), column == "A" ? "合计" : "", style: 6)
        }.joined() + "</row>"
        let widths = [7, 14, 13, 27, 15, 15, 26, 22]
        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetPr><pageSetUpPr fitToPage="1"/></sheetPr><dimension ref="A1:H\(total)"/>
        <sheetViews><sheetView workbookViewId="0" showGridLines="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
        <sheetFormatPr defaultRowHeight="24"/><cols>\(widths.enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\($0.element)\" customWidth=\"1\"/>" }.joined())</cols>
        <sheetData>\(data)</sheetData>\(last >= 2 ? "<autoFilter ref=\"A1:H\(last)\"/>" : "")
        <printOptions horizontalCentered="1"/><pageMargins left="0.25" right="0.25" top="0.4" bottom="0.4" header="0.2" footer="0.2"/>
        <pageSetup paperSize="9" orientation="landscape" fitToWidth="1" fitToHeight="0"/></worksheet>
        """
        let files = [
            "[Content_Types].xml": "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>",
            "_rels/.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
            "xl/workbook.xml": "<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><bookViews><workbookView/></bookViews><sheets><sheet name=\"报销清单\" sheetId=\"1\" r:id=\"rId1\"/></sheets><definedNames><definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">'报销清单'!$A$1:$H$\(total)</definedName><definedName name=\"_xlnm.Print_Titles\" localSheetId=\"0\">'报销清单'!$1:$1</definedName></definedNames><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>",
            "xl/_rels/workbook.xml.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>",
            "xl/worksheets/sheet1.xml": sheet,
            "xl/styles.xml": styles
        ]
        for (path, content) in files { try content.write(to: package.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let archive = staging.appendingPathComponent("ledger.xlsx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = package
        process.arguments = ["-q", "-r", archive.path, "."]
        process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReimburError("报销清单导出失败，原有文件未被覆盖。") }
        try Data(contentsOf: archive).write(to: destination, options: .atomic)
    }

    static func excelDate(_ key: String) -> Int? {
        guard let date = DayKey.date(key), DayKey.string(date) == key,
              let base = DayKey.calendar.date(from: DateComponents(year: 1899, month: 12, day: 30)) else { return nil }
        return DayKey.calendar.dateComponents([.day], from: base, to: date).day
    }
    private static func xml(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 })
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static var styles: String {
        let fonts = "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Arial\"/></font><font><b/><sz val=\"11\"/><name val=\"Arial\"/></font></fonts>"
        let fills = "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFEAF3FF\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>"
        let borders = "<borders count=\"2\"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style=\"thin\"><color rgb=\"FFD9D9D9\"/></left><right style=\"thin\"><color rgb=\"FFD9D9D9\"/></right><top style=\"thin\"><color rgb=\"FFD9D9D9\"/></top><bottom style=\"thin\"><color rgb=\"FFD9D9D9\"/></bottom><diagonal/></border></borders>"
        func style(_ format: Int = 0, bold: Bool = false, fill: Bool = false, center: Bool = false, right: Bool = false) -> String {
            "<xf numFmtId=\"\(format)\" fontId=\"\(bold ? 1 : 0)\" fillId=\"\(fill ? 2 : 0)\" borderId=\"1\" xfId=\"0\" applyNumberFormat=\"1\" applyAlignment=\"1\" applyBorder=\"1\" applyFont=\"1\" applyFill=\"1\"><alignment vertical=\"center\" horizontal=\"\(center ? "center" : right ? "right" : "left")\" wrapText=\"1\"/></xf>"
        }
        return "<?xml version=\"1.0\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"2\"><numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd\"/><numFmt numFmtId=\"165\" formatCode=\"#,##0.00\"/></numFmts>\(fonts)\(fills)\(borders)<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"8\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>\(style(bold: true, fill: true, center: true))\(style())\(style(165, right: true))\(style(164))\(style(49))\(style(bold: true, fill: true))\(style(165, bold: true, fill: true, right: true))</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
    }
}
