import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor final class ClaimStore: ObservableObject {
    @Published private(set) var claims: [Claim] = []
    @Published var errorMessage: String?
    @Published private(set) var ready = false
    @Published var exporting = false
    @Published var exportSuccess: URL?
    @Published var preview: PreviewRequest?
    @Published var showSettings = false
    private var deletedIDs = Set<UUID>()
    private var database: Database?
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reimbur", isDirectory: true)
        do {
            let database = try Database(root: self.root)
            let loaded = try database.load()
            claims = loaded.map(\.withPeopleAssigned)
            for (old, updated) in zip(loaded, claims) where old != updated { try database.save(updated) }
            self.database = database
            ready = true
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult func save(_ claim: Claim) -> Bool {
        guard let database, ready, !deletedIDs.contains(claim.id) else { return false }
        var updated = claim.withPeopleAssigned
        updated.updatedAt = Date()
        do {
            try database.save(updated)
            if let index = claims.firstIndex(where: { $0.id == updated.id }) { claims[index] = updated }
            else { claims.insert(updated, at: 0) }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func create(_ kind: ClaimKind, defaults: ExpenseDefaults = ExpenseDefaults()) -> UUID? {
        var claim = Claim.make(kind)
        claim.expenses[0].unitPrice = defaults.price(for: claim.expenses[0].kind)
        return save(claim) ? claim.id : nil
    }

    @discardableResult func delete(_ claim: Claim) -> Bool { delete(ids: [claim.id]) }

    @discardableResult func delete(ids: Set<UUID>) -> Bool {
        guard let database else { return false }
        let records = claims.filter { ids.contains($0.id) }
        do {
            try database.delete(ids: Set(records.map(\.id)))
            deletedIDs.formUnion(records.map(\.id))
            claims.removeAll { ids.contains($0.id) }
            for attachment in records.flatMap(\.attachments) { try? FileManager.default.removeItem(at: url(for: attachment)) }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func rename(_ id: UUID, to title: String) {
        guard var claim = claims.first(where: { $0.id == id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        claim.title = name
        _ = save(claim)
    }

    func url(for attachment: Attachment) -> URL { root.appendingPathComponent("Attachments").appendingPathComponent(attachment.storedName) }

    func importFiles(_ sources: [URL], into claim: Claim, expenseID: UUID?) throws -> Claim {
        guard ready else { throw ReimburError("数据库不可用，无法导入附件。") }
        if let expenseID {
            guard let expense = claim.expenses.first(where: { $0.id == expenseID }) else { throw ReimburError("费用项目已不存在。") }
            guard expense.kind.acceptsInvoices else { throw ReimburError("出差补助无需上传发票。") }
        }
        var updated = claim
        var imported: [Attachment] = []
        do {
            for source in sources {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let attachmentID = UUID()
                let name = attachmentID.uuidString + "." + source.pathExtension.lowercased()
                var attachment = Attachment(id: attachmentID, name: source.lastPathComponent, storedName: name)
                if expenseID != nil {
                    guard source.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount > 0 else {
                        throw ReimburError("\(source.lastPathComponent) 不是有效的 PDF，或文件已加密。")
                    }
                    attachment.pageCount = pdf.pageCount
                } else {
                    guard let image = NSImage(contentsOf: source), image.isValid else {
                        throw ReimburError("无法读取图片 \(source.lastPathComponent)，请选择 PNG、JPEG、HEIC、TIFF 等常见图片。")
                    }
                }
                try FileManager.default.copyItem(at: source, to: url(for: attachment))
                imported.append(attachment)
            }
            if let expenseID {
                guard let index = updated.expenses.firstIndex(where: { $0.id == expenseID }) else { throw ReimburError("费用项目已不存在。") }
                updated.expenses[index].invoices += imported
            } else { updated.covers += imported }
            guard save(updated) else { throw ReimburError(errorMessage ?? "保存附件失败。") }
            return updated.withPeopleAssigned
        } catch {
            for attachment in imported { try? FileManager.default.removeItem(at: url(for: attachment)) }
            throw error
        }
    }

    func removeAttachment(_ attachment: Attachment, from claim: Claim, expenseID: UUID?) -> Claim? {
        var updated = claim
        if let expenseID {
            guard let index = updated.expenses.firstIndex(where: { $0.id == expenseID }),
                  updated.expenses[index].invoices.contains(where: { $0.id == attachment.id }) else { return nil }
            updated.expenses[index].invoices.removeAll { $0.id == attachment.id }
        } else {
            guard updated.covers.contains(where: { $0.id == attachment.id }) else { return nil }
            updated.covers.removeAll { $0.id == attachment.id }
        }
        guard save(updated) else { return nil }
        try? FileManager.default.removeItem(at: url(for: attachment))
        return updated.withPeopleAssigned
    }

    func chooseFiles(for claim: Claim, expenseID: UUID?) -> Claim? {
        let panel = NSOpenPanel()
        panel.title = expenseID == nil ? "上传报销单图片" : "上传 PDF 发票"
        panel.allowedContentTypes = expenseID == nil ? [.png, .jpeg, .heic, .tiff, .bmp, .gif] : [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        do { return try importFiles(panel.urls, into: claim, expenseID: expenseID) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func export(_ records: [Claim]) {
        guard !records.isEmpty, !exporting else { return }
        let panel = NSSavePanel()
        panel.title = "导出 Word 打印文档"
        panel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
        panel.nameFieldStringValue = records.count == 1 ? "\(records[0].title).docx" : "报销发票汇总.docx"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        let attachmentRoot = root.appendingPathComponent("Attachments")
        let packInvoices = UserDefaults.standard.object(forKey: "packLandscapeInvoices") as? Bool ?? true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try WordExporter.export(claims: records, attachmentRoot: attachmentRoot, to: destination, packLandscapeInvoices: packInvoices)
                }.value
                exporting = false
                exportSuccess = destination
            } catch { exporting = false; errorMessage = error.localizedDescription }
        }
    }
}
