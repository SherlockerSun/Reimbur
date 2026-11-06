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
    @Published var recordPreview: RecordPreviewRequest?
    let hoverPreview = AttachmentHoverSession()
    @Published var showSettings = false
    private var deletedIDs = Set<UUID>()
    private var database: Database?
    let root: URL

    func hoverAttachment(_ attachment: Attachment, location: CGPoint?) {
        guard preview == nil, recordPreview == nil else { hoverPreview.clear(); return }
        hoverPreview.track(attachment, url: url(for: attachment), location: location)
    }
    func previewSummary(_ claim: Claim, personID: String? = nil) {
        dismissPreview()
        recordPreview = .summary(claim, personID)
    }
    func previewTripForm(_ claim: Claim) {
        dismissPreview()
        recordPreview = .tripForm(claim)
    }
    func dismissPreview() {
        preview = nil; recordPreview = nil; hoverPreview.clear()
    }

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
        claim.department = defaults.department
        if kind == .trip { claim.tripPurpose = defaults.tripPurpose }
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
        dismissPreview()
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

    func importFiles(_ sources: [URL], into claim: Claim, expenseID: UUID?, role: ExpenseAttachmentRole = .invoice, naming: AttachmentNaming = .saved(), persist: Bool = true) throws -> Claim {
        guard ready else { throw ReimburError("数据库不可用，无法导入附件。") }
        if let expenseID {
            guard let expense = claim.expenses.first(where: { $0.id == expenseID }) else { throw ReimburError("费用项目已不存在。") }
            if role == .itinerary {
                guard expense.kind == .taxi else { throw ReimburError("行程单仅用于打车费用。") }
                guard (expense.itineraries ?? []).count + sources.count <= max(1, expense.invoices.count) else {
                    throw ReimburError("每张发票仅对应一份行程单，请先移除原行程单或调整归属。")
                }
            } else {
                guard expense.kind.acceptsInvoices else { throw ReimburError("出差补助无需上传发票。") }
            }
        } else if role == .itinerary { throw ReimburError("请选择打车费用后上传行程单。") }
        var updated = claim.withPeopleAssigned.withDirectHotelTotals.withInvoiceLedger.withAllowanceTotal
        var imported: [Attachment] = []
        var recognizedAmount = false
        var routes = Set<RailRoute>()
        var railTimes = Set<RailTimes>()
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
                            if let times = metadata.railTimes { railTimes.insert(times) }
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
                    updated.invoiceLedgerEntries = (updated.invoiceLedgerEntries ?? []) + imported.map { attachment in
                        InvoiceLedgerEntry(id: attachment.id, expenseID: expenseID, invoiceID: attachment.id,
                                           date: updated.expenses[index].departureTime.flatMap(RailMoment.dayKey)
                                               ?? updated.expenses[index].dates?.sorted().first
                                               ?? updated.dates.sorted().first ?? DayKey.string(updated.createdAt),
                                           claimant: updated.expenses[index].claimant ?? updated.travelerNames?.first,
                                           reimbursementAmount: attachment.amount,
                                           detail: updated.kind == .trip ? updated.expenses[index].kind.displayName : updated.expenses[index].note)
                    }
                    if updated.expenses[index].synchronizesInvoiceTotal && (recognizedAmount || updated.expenses[index].invoiceTotalLinked == true) {
                        updated.expenses[index].synchronizeInvoiceTotal()
                    }
                    if updated.expenses[index].kind == .train, routes.count == 1, let route = routes.first {
                        updated.expenses[index].applyRecognizedRailRoute(route)
                    }
                    if updated.expenses[index].kind == .train {
                        let departures = Set(railTimes.compactMap(\.departure)), arrivals = Set(railTimes.compactMap(\.arrival))
                        if departures.count == 1 { updated.expenses[index].departureTime = departures.first }
                        if arrivals.count == 1 { updated.expenses[index].arrivalTime = arrivals.first }
                    }
                }
            } else { updated.covers += imported }
            guard !persist || save(updated) else { throw ReimburError(errorMessage ?? "保存附件失败。") }
            return updated.withPeopleAssigned
        } catch {
            for attachment in imported { discardFile(attachment) }
            throw error
        }
    }

    /// One batch is one database write. Any copy, recognition or save failure rolls back only
    /// this batch's new files; existing expenses and attachments are left intact.
    func importTripFiles(_ sources: [URL], into claim: Claim, kind: ExpenseKind, naming: AttachmentNaming = .saved()) throws -> Claim {
        guard ready, claim.kind == .trip, claim.kind.categories.contains(kind), kind.acceptsInvoices else {
            throw ReimburError("请选择交通或住宿费用导入发票。")
        }
        guard !sources.isEmpty else { return claim }
        let files = try sources.map { try TripImportRecognition.inspect($0, kind: kind) }
        var updated = claim.withPeopleAssigned.withDirectHotelTotals.withInvoiceLedger
        let originalIDs = Set(claim.attachments.map(\.id))
        var matches: [String: Set<UUID>] = [:]
        func register(_ key: String?, prefix: String, expenseID: UUID) {
            if let key { matches[prefix + key, default: []].insert(expenseID) }
        }
        for expense in updated.expenses where expense.kind == kind {
            for invoice in expense.invoices { register(invoice.number, prefix: "invoice:", expenseID: expense.id) }
        }
        func emptyRow() -> UUID? {
            updated.expenses.first { $0.kind == kind && $0.attachments.isEmpty && $0.total(in: updated) == 0 &&
                $0.note.isEmpty && $0.origin.isEmpty && $0.destination.isEmpty && $0.dates == nil && $0.departureTime == nil && $0.arrivalTime == nil }?.id
        }
        var importedInvoiceIDs: [UUID] = []
        do {
            // Process invoices first so a mixed selection works regardless of file-picker order.
            for file in files where file.role == .invoice {
                let expenseID: UUID
                if let empty = emptyRow() { expenseID = empty }
                else {
                    updated.addExpense(kind, unitPrice: 0)
                    expenseID = updated.expenses.last!.id
                }
                updated = try importFiles([file.source], into: updated, expenseID: expenseID, naming: naming, persist: false)
                importedInvoiceIDs.append(expenseID)
                register(file.invoiceNumber, prefix: "invoice:", expenseID: expenseID)
                register(file.orderNumber, prefix: "order:", expenseID: expenseID)
                if let number = updated.expenses.first(where: { $0.id == expenseID })?.invoices.last?.number {
                    register(number, prefix: "invoice:", expenseID: expenseID)
                }
            }
            for file in files where file.role == .itinerary {
                var candidates = Set<UUID>()
                if let number = file.invoiceNumber { candidates.formUnion(matches["invoice:" + number] ?? []) }
                if let order = file.orderNumber { candidates.formUnion(matches["order:" + order] ?? []) }
                let expenseID: UUID
                func hasFreeSlot(_ id: UUID) -> Bool {
                    guard let expense = updated.expenses.first(where: { $0.id == id }) else { return false }
                    return (expense.itineraries ?? []).count < max(1, expense.invoices.count)
                }
                if candidates.count == 1, let matched = candidates.first, hasFreeSlot(matched) { expenseID = matched }
                else if candidates.isEmpty, file.invoiceNumber == nil, file.orderNumber == nil, importedInvoiceIDs.count == 1, hasFreeSlot(importedInvoiceIDs[0]) {
                    expenseID = importedInvoiceIDs[0]
                } else {
                    if let empty = emptyRow() { expenseID = empty }
                    else { updated.addExpense(kind, unitPrice: 0); expenseID = updated.expenses.last!.id }
                    if let index = updated.expenses.firstIndex(where: { $0.id == expenseID }) { updated.expenses[index].note = "行程单（待关联）" }
                }
                updated = try importFiles([file.source], into: updated, expenseID: expenseID, role: .itinerary, naming: naming, persist: false)
            }
            guard save(updated) else { throw ReimburError(errorMessage ?? "保存导入清单失败。") }
            return updated
        } catch {
            for attachment in updated.attachments where !originalIDs.contains(attachment.id) { discardFile(attachment) }
            throw error
        }
    }

    func chooseTripFiles(for claim: Claim, kind: ExpenseKind) -> Claim? {
        let panel = NSOpenPanel()
        panel.title = "导入"
        panel.allowedContentTypes = kind == .taxi ? [.pdf, .png, .jpeg, .heic, .tiff, .bmp, .gif] : [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        do { return try importTripFiles(panel.urls, into: claim, kind: kind) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func moveItinerary(_ attachment: Attachment, in claim: Claim, from sourceID: UUID, to destinationID: UUID) -> Claim? {
        var updated = claim
        guard sourceID != destinationID,
              let source = updated.expenses.firstIndex(where: { $0.id == sourceID && $0.kind == .taxi }),
              let destination = updated.expenses.firstIndex(where: { $0.id == destinationID && $0.kind == .taxi }),
              updated.expenses[source].itineraries?.contains(where: { $0.id == attachment.id }) == true else { return nil }
        guard (updated.expenses[destination].itineraries ?? []).count < max(1, updated.expenses[destination].invoices.count) else {
            errorMessage = "目标发票已有行程单，请先移除或调整归属。"; return nil
        }
        updated.expenses[source].itineraries?.removeAll { $0.id == attachment.id }
        updated.expenses[destination].itineraries = (updated.expenses[destination].itineraries ?? []) + [attachment]
        guard save(updated) else { return nil }
        return updated
    }

    private func copyAttachment(_ source: Attachment, usedNames: inout Set<String>) throws -> Attachment {
        var copy = source
        copy.id = UUID()
        copy.name = AttachmentNaming.uniqueFilename(source.name, usedNames: &usedNames)
        copy.storedName = copy.id.uuidString + "/" + copy.name
        let destination = url(for: copy)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url(for: source), to: destination)
        } catch { discardFile(copy); throw error }
        return copy
    }

    func duplicateExpense(_ id: UUID, in claim: Claim) throws -> Claim {
        guard claim.kind == .trip, let index = claim.expenses.firstIndex(where: { $0.id == id }) else { throw ReimburError("费用行已不存在。") }
        var updated = claim
        var copy = claim.expenses[index]
        copy.id = UUID(); copy.subsidyGroupID = nil
        var used = Set(claim.attachments.map { $0.name.lowercased() })
        var added: [Attachment] = []
        do {
            copy.invoices = try copy.invoices.map { let file = try copyAttachment($0, usedNames: &used); added.append(file); return file }
            copy.itineraries = try copy.itineraries.map { try $0.map { let file = try copyAttachment($0, usedNames: &used); added.append(file); return file } }
            updated.expenses.insert(copy, at: index + 1)
            guard save(updated) else { throw ReimburError(errorMessage ?? "复制费用行失败。") }
            return updated
        } catch { for file in added { discardFile(file) }; throw error }
    }

    func duplicateLedgerRow(_ id: UUID, in claim: Claim) throws -> Claim {
        var updated = claim.withInvoiceLedger
        guard let rowIndex = updated.invoiceLedgerEntries?.firstIndex(where: { $0.id == id }),
              let original = updated.invoiceLedgerEntries?[rowIndex],
              let expenseIndex = updated.expenses.firstIndex(where: { $0.id == original.expenseID }) else { throw ReimburError("清单行已不存在。") }
        var copy = original; copy.id = UUID()
        var added: Attachment?
        do {
            if let source = updated.expenses[expenseIndex].invoices.first(where: { $0.id == original.invoiceID }) {
                var used = Set(claim.attachments.map { $0.name.lowercased() })
                let file = try copyAttachment(source, usedNames: &used); added = file
                copy.invoiceID = file.id
                let invoiceIndex = updated.expenses[expenseIndex].invoices.firstIndex(where: { $0.id == source.id })!
                updated.expenses[expenseIndex].invoices.insert(file, at: invoiceIndex + 1)
            }
            updated.invoiceLedgerEntries?.insert(copy, at: rowIndex + 1)
            guard save(updated) else { throw ReimburError(errorMessage ?? "复制清单行失败。") }
            return updated
        } catch { if let added { discardFile(added) }; throw error }
    }

    func removeLedgerRow(_ id: UUID, in claim: Claim) -> Claim? {
        guard let row = claim.invoiceLedgerEntries?.first(where: { $0.id == id }) else { return nil }
        if let invoice = claim.expenses.first(where: { $0.id == row.expenseID })?.invoices.first(where: { $0.id == row.invoiceID }) {
            return removeAttachment(invoice, from: claim, expenseID: row.expenseID)
        }
        var updated = claim; updated.invoiceLedgerEntries?.removeAll { $0.id == id }
        return save(updated) ? updated : nil
    }

    func chooseLedgerRowInvoice(_ id: UUID, in claim: Claim) -> Claim? {
        guard let entry = claim.invoiceLedgerEntries?.first(where: { $0.id == id }) else { return nil }
        let panel = NSOpenPanel(); panel.title = "上传发票"; panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        do { return try replaceLedgerRowInvoice(id, with: source, in: claim, expenseID: entry.expenseID) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    func replaceLedgerRowInvoice(_ id: UUID, with source: URL, in claim: Claim, expenseID: UUID) throws -> Claim {
        guard let rowIndex = claim.invoiceLedgerEntries?.firstIndex(where: { $0.id == id }),
              let original = claim.invoiceLedgerEntries?[rowIndex], original.expenseID == expenseID,
              let expenseIndex = claim.expenses.firstIndex(where: { $0.id == expenseID }) else { throw ReimburError("清单行已不存在。") }
        var updated = try importFiles([source], into: claim, expenseID: expenseID, persist: false)
        let old = claim.expenses[expenseIndex].invoices.first { $0.id == original.invoiceID }
        guard let added = updated.expenses[expenseIndex].invoices.last else { throw ReimburError("上传发票失败。") }
        updated.invoiceLedgerEntries?.removeLast()
        updated.invoiceLedgerEntries?[rowIndex].invoiceID = added.id
        if let old { updated.expenses[expenseIndex].invoices.removeAll { $0.id == old.id } }
        guard save(updated) else { discardFile(added); throw ReimburError(errorMessage ?? "保存发票失败。") }
        if let old { discardFile(old) }
        return updated
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
        panel.title = "导出发票（含行程单）"
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
        panel.title = "打印发票"
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
        guard !exporting else { return }
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
