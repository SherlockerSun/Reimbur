import AppKit
import PDFKit
import Vision

// Settings are read when a record or attachment is created, so existing data keeps its values.
enum AppPreferences {
    static let defaultCaption = "轻记每一笔，安心每一天"
    static let captionLimit = 14
    static func caption(_ value: String) -> String { String(value.filter { !$0.isNewline }.prefix(captionLimit)) }
    static func decodeNames(_ value: String) -> [String] {
        let names = (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    static func encodeNames(_ names: [String]) -> String {
        String(data: (try? JSONEncoder().encode(names)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }
    static func travelerNames(in defaults: UserDefaults) -> [String] { decodeNames(defaults.string(forKey: "defaultTravelerNames") ?? "[]") }
}

enum ExpenseAttachmentRole { case invoice, itinerary }

struct AttachmentNaming {
    static let defaultFormat = "{报销人}{发票号码}"
    var invoiceFormat = Self.defaultFormat
    var itineraryFormat = Self.defaultFormat
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(invoiceFormat: defaults.string(forKey: "invoiceNameFormat") ?? defaultFormat,
             itineraryFormat: defaults.string(forKey: "itineraryNameFormat") ?? defaultFormat)
    }
    func filename(source: URL, number: String?, claim: Claim, expense: Expense, role: ExpenseAttachmentRole) -> String {
        let original = source.deletingPathExtension().lastPathComponent
        let pattern = role == .invoice ? invoiceFormat : itineraryFormat
        var value = pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultFormat : pattern
        let linkedNumbers = Set(expense.invoices.compactMap { $0.number ?? Self.number(in: "", filename: $0.name, role: .invoice) })
        let invoiceNumber = number ?? (role == .itinerary && linkedNumbers.count == 1 ? linkedNumbers.first : nil)
        let fields = ["报销人": expense.claimant ?? claim.travelerNames?.first ?? "未分配", "发票号码": invoiceNumber ?? original,
                      "行程单号": number ?? original, "报销名称": claim.title, "费用类型": expense.kind.rawValue,
                      "原文件名": original, "日期": claim.dates.sorted().first ?? DayKey.string(claim.createdAt)]
        for (key, replacement) in fields { value = value.replacingOccurrences(of: "{\(key)}", with: replacement) }
        return Self.safeStem(value, fallback: original) + "." + source.pathExtension.lowercased()
    }
    static func safeStem(_ value: String, fallback: String = "附件") -> String {
        let disallowed = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let clean = value.components(separatedBy: disallowed).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = clean.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(100))
    }
    // Reserve each name immediately so duplicates within a single upload batch also get a suffix.
    static func uniqueFilename(_ filename: String, usedNames: inout Set<String>) -> String {
        let file = URL(fileURLWithPath: filename)
        let stem = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
        var candidate = filename
        var index = 1
        while !usedNames.insert(candidate.lowercased()).inserted {
            candidate = "\(stem)_\(index)\(ext)"
            index += 1
        }
        return candidate
    }
    static func number(in text: String, filename: String = "", role: ExpenseAttachmentRole) -> String? {
        func first(_ pattern: String, in value: String, capture: Int = 1) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: capture), in: value) else { return nil }
            return String(value[range]).replacingOccurrences(of: " ", with: "")
        }
        if role == .itinerary, let value = first(#"(?:行\s*程\s*单\s*(?:编\s*号|号)|订\s*单\s*号)[：:\s]*([A-Z0-9-]{6,40})"#, in: text) { return value }
        if let value = first(#"(?:发\s*票\s*(?:号\s*码|编\s*号)|票\s*据\s*号\s*码)[：:\s]*([0-9]{8,20})(?![0-9])"#, in: text) { return value }
        if let value = first(#"(?<![0-9])([0-9]{20})(?![0-9])"#, in: text) { return value }
        return first(#"(?<![0-9])([0-9]{20}|[0-9]{8})(?![0-9])"#, in: filename)
    }
    static func number(in pdf: PDFDocument, source: URL, role: ExpenseAttachmentRole) -> String? {
        AttachmentRecognition.read(pdf: pdf, source: source, role: role).number
    }
}

struct AttachmentMetadata {
    var number: String?
    var amount: Int64?
    var route: RailRoute?
}

struct RailRoute: Hashable {
    var origin: String
    var destination: String
}

enum AttachmentRecognition {
    static func trainRoute(in text: String) -> RailRoute? {
        let text = text.folding(options: .widthInsensitive, locale: Locale(identifier: "zh_CN"))
            .replacingOccurrences(of: "\r", with: "\n")
        func captures(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } }
        }
        let station = #"([\p{Han}]{2,16})"#
        let origin = captures(#"(?:出发站|出发地|起始站|始发站|乘车站|发站|起始地)[：:\s]*"# + station)?.first
        let destination = captures(#"(?:到达站|到达地|终到站|终点站|到站|目的地)[：:\s]*"# + station)?.first
        if let origin, let destination { return RailRoute(origin: origin, destination: destination) }
        let patterns = [
            station + #"\s*(?:→|➜|⟶|->|—>|-->|至)\s*"# + station,
            #"(?m)^\s*"# + station + #"[ \t]*(?:\n[A-Za-z][A-Za-z \t]*[ \t]*)?\s+[GDCZTKLSY][0-9]{1,4}次?\s+"# + station,
            #"(?m)^\s*"# + station + #"[ \t]+"# + station + #"\s*\n(?:[A-Za-z \t]+\n)?\s*[GDCZTKLSY][0-9]{1,4}次?\b"#
        ]
        for pattern in patterns {
            if let values = captures(pattern), values.count == 2 { return RailRoute(origin: values[0], destination: values[1]) }
        }
        // OCR may omit the arrow between the two station names on the same line.
        let excluded = ["发票", "样本", "金额", "合计", "铁路", "客票", "旅客", "姓名", "证件", "购买", "销售", "名称", "项目", "税", "座", "票价", "备注", "开票", "出发", "到达", "乘车", "车次", "时间", "日期", "身份证"]
        for line in text.components(separatedBy: .newlines) where !excluded.contains(where: { line.contains($0) }) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if parts.count == 2 && parts.allSatisfy({ $0.range(of: #"^[\p{Han}]{2,12}$"#, options: .regularExpression) != nil }) {
                return RailRoute(origin: parts[0], destination: parts[1])
            }
        }
        return nil
    }
    static func amount(in text: String) -> Int64? {
        let text = text.folding(options: .widthInsensitive, locale: Locale(identifier: "zh_CN"))
            .replacingOccurrences(of: #"[\t \u00a0]"#, with: "", options: .regularExpression)
        let value = #"([-−]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]{1,9})(?:\.[0-9]{1,2})?)(?![0-9.,])"#
        // Prefer the tax-inclusive total, never the line-item price or pre-tax subtotal.
        let patterns = [
            #"(?:\(小写\)|小写金额|小写)[：:\s]*[¥￥]?\s*"# + value,
            #"价税合计[^0-9¥￥−-]{0,100}[¥￥]?\s*"# + value,
            #"票价(?:\([^\)\n]{0,12}\))?[：:\s]*(?:人民币|CNY|RMB)?[¥￥]?\s*"# + value,
            #"(?:实付金额|支付金额|应付金额|合计金额|总金额|票面金额|金额合计|含税金额|实付)[：:\s]*[¥￥]?\s*"# + value
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return Money.parse(String(text[range]).replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }
    static func read(pdf: PDFDocument, source: URL, role: ExpenseAttachmentRole, kind: ExpenseKind? = nil) -> AttachmentMetadata {
        let text = (0..<min(pdf.pageCount, 2)).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        var result = metadata(text: text, source: source, role: role, kind: kind)
        guard result.number == nil || (role == .invoice && result.amount == nil) || (kind == .train && result.route == nil) else { return result }
        // Scans and PDFs with incomplete text layers are recognized locally, once for both fields.
        for index in 0..<min(pdf.pageCount, 2) {
            guard let page = pdf.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let scale = min(3, 2400 / max(bounds.width, bounds.height))
            let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            let recognized = read(image: image, source: source, role: role, kind: kind)
            result.number = result.number ?? recognized.number
            result.amount = result.amount ?? recognized.amount
            result.route = result.route ?? recognized.route
            if result.number != nil && (role == .itinerary || result.amount != nil) && (kind != .train || result.route != nil) { break }
        }
        return result
    }
    static func read(image: NSImage, source: URL, role: ExpenseAttachmentRole, kind: ExpenseKind? = nil) -> AttachmentMetadata {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return metadata(text: "", source: source, role: role, kind: kind) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return metadata(text: recognized, source: source, role: role, kind: kind)
    }
    private static func metadata(text: String, source: URL, role: ExpenseAttachmentRole, kind: ExpenseKind? = nil) -> AttachmentMetadata {
        AttachmentMetadata(number: AttachmentNaming.number(in: text, filename: source.deletingPathExtension().lastPathComponent, role: role),
                           amount: role == .invoice ? amount(in: text) : nil, route: kind == .train && role == .invoice ? trainRoute(in: text) : nil)
    }
}

enum InvoiceArchiveExporter {
    static func export(claim: Claim, attachmentRoot: URL, to destination: URL) throws {
        let fm = FileManager.default
        let attachments = claim.expenses.flatMap(\.attachments)
        guard !attachments.isEmpty else { throw ReimburError("这条记录还没有发票或行程单。") }
        let staging = fm.temporaryDirectory.appendingPathComponent("Reimbur-invoices-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(AttachmentNaming.safeStem(claim.title, fallback: "报销发票"), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var used = Set<String>()
        for attachment in attachments {
            let original = URL(fileURLWithPath: attachment.name)
            let stem = AttachmentNaming.safeStem(original.deletingPathExtension().lastPathComponent)
            let ext = original.pathExtension.isEmpty ? "pdf" : original.pathExtension
            let name = AttachmentNaming.uniqueFilename("\(stem).\(ext)", usedNames: &used)
            let source = attachmentRoot.appendingPathComponent(attachment.storedName)
            guard fm.fileExists(atPath: source.path) else { throw ReimburError("附件已丢失：\(attachment.name)") }
            try fm.copyItem(at: source, to: folder.appendingPathComponent(name))
        }
        let archive = staging.appendingPathComponent("output.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-q", "-r", archive.path, folder.lastPathComponent]
        process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReimburError("发票打包失败，原有文件未被覆盖。") }
        try Data(contentsOf: archive, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }
}
