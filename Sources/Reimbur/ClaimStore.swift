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
            claims = loaded.map { $0.withPeopleAssigned.withDirectHotelTotals.withInvoiceLedger.withAllowanceTotal }
            for (old, updated) in zip(loaded, claims) where old != updated { try database.save(updated) }
            self.database = database
            ready = true
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult func save(_ claim: Claim) -> Bool {
        guard let database, ready, !deletedIDs.contains(claim.id) else { return false }
        var updated = claim.withPeopleAssigned.withDirectHotelTotals.withInvoiceLedger.withAllowanceTotal
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
        claim.setTravelerNames(defaults.travelerNames)
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
            for attachment in records.flatMap(\.attachments) { discardFile(attachment) }
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

    @discardableResult func setStatus(_ status: ClaimStatus, for id: UUID) -> Bool {
        guard var claim = claims.first(where: { $0.id == id }) else { return false }
        claim.status = status
        return save(claim)
    }

    func url(for attachment: Attachment) -> URL { root.appendingPathComponent("Attachments").appendingPathComponent(attachment.storedName) }

    func previewAttachment(_ attachment: Attachment, in claim: Claim) {
        guard FileManager.default.fileExists(atPath: url(for: attachment).path) else {
            errorMessage = "附件已丢失：\(attachment.name)"; return
        }
        preview = PreviewRequest(attachments: claim.attachments, selected: attachment, attachmentRoot: root.appendingPathComponent("Attachments"))
    }

    func renameAttachment(_ attachment: Attachment, to stem: String, in claim: Claim, expenseID: UUID) throws -> Claim {
        guard let index = claim.expenses.firstIndex(where: { $0.id == expenseID }),
              let current = claim.expenses[index].attachments.first(where: { $0.id == attachment.id }) else { throw ReimburError("附件已不存在。") }
        guard !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReimburError("附件名称不能为空。") }
        let ext = URL(fileURLWithPath: current.name).pathExtension
        let proposed = AttachmentNaming.safeStem(stem) + (ext.isEmpty ? "" : "." + ext)
        if proposed == current.name { return claim }
        var used = Set(claim.expenses.flatMap(\.attachments).filter { $0.id != current.id }.map { $0.name.lowercased() })
        var renamed = current
        renamed.name = AttachmentNaming.uniqueFilename(proposed, usedNames: &used)
        renamed.storedName = current.id.uuidString + "/" + renamed.name
        let source = url(for: current), destination = url(for: renamed)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw ReimburError("附件已丢失：\(current.name)") }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An intermediate path also supports changing only the letter case on APFS.
        let staging = source.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID())")
        try fm.moveItem(at: source, to: staging)
        do { try fm.moveItem(at: staging, to: destination) }
        catch { try? fm.moveItem(at: staging, to: source); throw error }
        var updated = claim
        if let fileIndex = updated.expenses[index].invoices.firstIndex(where: { $0.id == current.id }) {
            updated.expenses[index].invoices[fileIndex] = renamed
        } else if let fileIndex = updated.expenses[index].itineraries?.firstIndex(where: { $0.id == current.id }) {
            updated.expenses[index].itineraries?[fileIndex] = renamed
        }
        guard save(updated) else {
            do { try fm.moveItem(at: destination, to: source) }
            catch { throw ReimburError("保存名称失败，附件副本保留在：\(destination.path)") }
            throw ReimburError(errorMessage ?? "保存附件名称失败。")
        }
        return updated
    }

    func importFiles(_ sources: [URL], into claim: Claim, expenseID: UUID?, role: ExpenseAttachmentRole = .invoice, naming: AttachmentNaming = .saved()) throws -> Claim {
        guard ready else { throw ReimburError("数据库不可用，无法导入附件。") }
        if let expenseID {
            guard let expense = claim.expenses.first(where: { $0.id == expenseID }) else { throw ReimburError("费用项目已不存在。") }
            if role == .itinerary {
                guard expense.kind == .taxi else { throw ReimburError("行程单仅用于打车费用。") }
            } else {
                guard expense.kind.acceptsInvoices else { throw ReimburError("出差补助无需上传发票。") }
            }
        } else if role == .itinerary { throw ReimburError("请选择打车费用后上传行程单。") }
        var updated = claim.withPeopleAssigned.withDirectHotelTotals.withInvoiceLedger.withAllowanceTotal
        var imported: [Attachment] = []
        var recognizedAmount = false
        var routes = Set<RailRoute>()
        var usedNames = Set(updated.expenses.flatMap(\.attachments).map { $0.name.lowercased() })
        do {
            for source in sources {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let attachmentID = UUID()
                var attachment = Attachment(id: attachmentID, name: source.lastPathComponent, storedName: "")
                if expenseID != nil {
                    if source.pathExtension.lowercased() == "pdf" {
                        guard let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount > 0 else {
                            throw ReimburError("\(source.lastPathComponent) 不是有效的 PDF，或文件已加密。")
                        }
                        attachment.pageCount = pdf.pageCount
                        let metadata = AttachmentRecognition.read(pdf: pdf, source: source, role: role, kind: updated.expenses.first { $0.id == expenseID }?.kind)
                        attachment.number = metadata.number
                        if role == .invoice {
                            attachment.amount = metadata.amount ?? 0
                            recognizedAmount = recognizedAmount || metadata.amount != nil
                            if let route = metadata.route { routes.insert(route) }
                        }
                    } else if role == .itinerary, let image = NSImage(contentsOf: source), image.isValid {
                        attachment.number = AttachmentRecognition.read(image: image, source: source, role: role).number
                    } else { throw ReimburError("\(source.lastPathComponent) 格式无效；发票请选择 PDF，行程单支持 PDF 或常见图片。") }
                    if let expense = updated.expenses.first(where: { $0.id == expenseID }) {
                        attachment.name = naming.filename(source: source, number: attachment.number, claim: updated, expense: expense, role: role)
                        attachment.name = AttachmentNaming.uniqueFilename(attachment.name, usedNames: &usedNames)
                    }
                } else {
                    guard let image = NSImage(contentsOf: source), image.isValid else {
                        throw ReimburError("无法读取图片 \(source.lastPathComponent)，请选择 PNG、JPEG、HEIC、TIFF 等常见图片。")
                    }
                }
                // Private directories keep each attachment independent while preserving its chosen filename.
                attachment.storedName = attachmentID.uuidString + "/" + attachment.name
                let destination = url(for: attachment)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                imported.append(attachment)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            if let expenseID {
                guard let index = updated.expenses.firstIndex(where: { $0.id == expenseID }) else { throw ReimburError("费用项目已不存在。") }
                if role == .itinerary { updated.expenses[index].itineraries = (updated.expenses[index].itineraries ?? []) + imported }
                else {
                    updated.expenses[index].invoices += imported
                    if updated.kind != .trip {
                        updated.invoiceLedgerEntries = (updated.invoiceLedgerEntries ?? []) + imported.map { attachment in
                            InvoiceLedgerEntry(id: attachment.id, expenseID: expenseID, invoiceID: attachment.id,
                                               date: updated.dates.sorted().first ?? DayKey.string(updated.createdAt),
                                               claimant: updated.expenses[index].claimant ?? updated.travelerNames?.first,
                                               reimbursementAmount: attachment.amount)
                        }
                    }
                    if updated.expenses[index].synchronizesInvoiceTotal && (recognizedAmount || updated.expenses[index].invoiceTotalLinked == true) {
                        updated.expenses[index].synchronizeInvoiceTotal()
                    }
                    if updated.expenses[index].kind == .train, routes.count == 1, let route = routes.first {
                        updated.expenses[index].origin = route.origin
                        updated.expenses[index].destination = route.destination
                    }
                }
            } else { updated.covers += imported }
            guard save(updated) else { throw ReimburError(errorMessage ?? "保存附件失败。") }
            return updated.withPeopleAssigned
        } catch {
            for attachment in imported { discardFile(attachment) }
            throw error
        }
    }

    func removeAttachment(_ attachment: Attachment, from claim: Claim, expenseID: UUID?) -> Claim? {
        var updated = claim
        if let expenseID {
            guard let index = updated.expenses.firstIndex(where: { $0.id == expenseID }),
                  updated.expenses[index].attachments.contains(where: { $0.id == attachment.id }) else { return nil }
            updated.expenses[index].invoices.removeAll { $0.id == attachment.id }
            updated.invoiceLedgerEntries?.removeAll { $0.invoiceID == attachment.id }
            if updated.expenses[index].invoiceTotalLinked == true { updated.expenses[index].synchronizeInvoiceTotal() }
            if updated.expenses[index].itineraries != nil { updated.expenses[index].itineraries?.removeAll { $0.id == attachment.id } }
        } else {
            guard updated.covers.contains(where: { $0.id == attachment.id }) else { return nil }
            updated.covers.removeAll { $0.id == attachment.id }
        }
        guard save(updated) else { return nil }
        discardFile(attachment)
        return updated.withPeopleAssigned
    }

    func chooseFiles(for claim: Claim, expenseID: UUID?, role: ExpenseAttachmentRole = .invoice) -> Claim? {
        let panel = NSOpenPanel()
        panel.title = expenseID == nil ? "上传报销单图片" : role == .itinerary ? "上传打车行程单" : "上传 PDF 发票"
        panel.allowedContentTypes = expenseID == nil ? [.png, .jpeg, .heic, .tiff, .bmp, .gif] : role == .itinerary ? [.pdf, .png, .jpeg, .heic, .tiff, .bmp, .gif] : [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        do { return try importFiles(panel.urls, into: claim, expenseID: expenseID, role: role) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func discardFile(_ attachment: Attachment) {
        let file = url(for: attachment)
        try? FileManager.default.removeItem(at: file)
        let parent = file.deletingLastPathComponent()
        if parent.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("Attachments").standardizedFileURL.path,
           (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    func exportInvoices(_ claim: Claim) {
        guard !exporting, !claim.expenses.flatMap(\.attachments).isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "导出当前报销的全部发票与行程单"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = AttachmentNaming.safeStem(claim.title) + "-发票.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        let attachmentRoot = root.appendingPathComponent("Attachments")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try InvoiceArchiveExporter.export(claim: claim, attachmentRoot: attachmentRoot, to: destination)
                }.value
                exporting = false; exportSuccess = destination
            } catch { exporting = false; errorMessage = error.localizedDescription }
        }
    }

    func export(_ records: [Claim]) {
        guard !records.isEmpty, !exporting else { return }
        let panel = NSSavePanel()
        panel.title = "导出打印文档"
        panel.allowedContentTypes = [UTType(filenameExtension: "docx")!]
        panel.nameFieldStringValue = records.count == 1 ? "\(records[0].title).docx" : "报销发票汇总.docx"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        let attachmentRoot = root.appendingPathComponent("Attachments")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try WordExporter.export(claims: records, attachmentRoot: attachmentRoot, to: destination)
                }.value
                exporting = false
                exportSuccess = destination
            } catch { exporting = false; errorMessage = error.localizedDescription }
        }
    }

    func exportLedger(_ claim: Claim) {
        guard !exporting, claim.kind != .trip else { return }
        let panel = NSSavePanel()
        panel.title = "导出 XLSX 报销清单"
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx")!]
        panel.nameFieldStringValue = AttachmentNaming.safeStem(claim.title) + "-报销清单.xlsx"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try LedgerExporter.export(claim: claim, to: destination) }.value
                exporting = false; exportSuccess = destination
            } catch { exporting = false; errorMessage = error.localizedDescription }
        }
    }
}
