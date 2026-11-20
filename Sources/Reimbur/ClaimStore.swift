import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

private final class ImportProgressBar: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var completed = false { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0, dy: 1)
        NSColor.systemGray.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let fill = CGRect(x: track.minX, y: track.minY, width: track.width * min(max(value, 0), 1), height: track.height)
        (failed ? NSColor.systemRed : completed ? NSColor.systemGreen : NSColor.systemBlue).setFill()
        NSBezierPath(roundedRect: fill, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }
}

private final class ClaimantImportPanelController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    var onUpload: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let popup: NSComboBox
    private let progress: ImportProgressBar
    private let status: NSTextField

    init(names: [String], kind: ClaimKind) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 300),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        popup = NSComboBox(frame: NSRect(x: 36, y: 165, width: 398, height: 28))
        progress = ImportProgressBar(frame: NSRect(x: 36, y: 132, width: 398, height: 8))
        status = NSTextField(labelWithString: "")
        super.init()
        panel.delegate = self
        panel.title = "上传发票"
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 300))
        let title = NSTextField(labelWithString: "上传发票")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 36, y: 235, width: 398, height: 28)
        let detail = NSTextField(labelWithString: "本次导入的发票将归入所选报销人。")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 2
        detail.frame = NSRect(x: 36, y: 185, width: 398, height: 42)
        popup.isEditable = true
        popup.addItems(withObjectValues: names)
        popup.stringValue = names.first ?? ""
        popup.font = .systemFont(ofSize: 13)
        popup.toolTip = "输入或选择报销人"
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 36, y: 102, width: 398, height: 22)
        status.isHidden = true
        progress.isHidden = true
        let upload = NSButton(title: "选择文件", target: self, action: #selector(uploadAction))
        upload.bezelStyle = .rounded
        upload.keyEquivalent = "\r"
        upload.frame = NSRect(x: 234, y: 20, width: 96, height: 32)
        let cancel = NSButton(title: "完成", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 338, y: 20, width: 96, height: 32)

        [title, detail, popup, progress, status, cancel, upload].forEach { content.addSubview($0) }
        panel.contentView = content
        panel.center()
    }

    var selectedClaimant: String { popup.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    func setNames(_ names: [String]) {
        let current = popup.stringValue
        popup.removeAllItems()
        popup.addItems(withObjectValues: names)
        popup.stringValue = current
    }
    func beginProgress() {
        progress.value = 0.06; progress.completed = false; progress.failed = false; progress.isHidden = false
        status.stringValue = "正在识别并整理发票…"; status.textColor = .secondaryLabelColor; status.isHidden = false
        panel.displayIfNeeded()
    }
    func updateProgress(_ value: Double) {
        progress.value = value
        panel.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.004))
    }
    func completeProgress(message: String) {
        progress.value = 1; progress.completed = true; progress.failed = false
        status.stringValue = message; status.textColor = .systemGreen; status.isHidden = false
        panel.displayIfNeeded()
    }
    func failProgress(message: String) {
        progress.completed = false; progress.failed = true; progress.isHidden = false
        status.stringValue = message; status.textColor = .systemRed; status.isHidden = false
        panel.displayIfNeeded()
    }
    @objc private func uploadAction() {
        let value = selectedClaimant
        guard !value.isEmpty else {
            status.stringValue = "请先填写或选择报销人"
            status.textColor = .systemRed; status.isHidden = false
            progress.isHidden = true
            return
        }
        onUpload?(value)
    }
    @objc private func cancelAction() { onCancel?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onCancel?(); return false }
}

@MainActor final class ClaimStore: ObservableObject {
    @Published private(set) var claims: [Claim] = []
    @Published var errorMessage: String?
    @Published private(set) var ready = false
    @Published var importSuccess: String?
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
    func previewReimbursementForm(_ claim: Claim) {
        dismissPreview()
        recordPreview = .reimbursementForm(claim)
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
        if kind == .meal { claim.reimbursementPurpose = defaults.mealPurpose }
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
                    } else if let image = NSImage(contentsOf: source), image.isValid {
                        let metadata = AttachmentRecognition.read(image: image, source: source, role: role, kind: updated.expenses.first { $0.id == expenseID }?.kind)
                        attachment.number = metadata.number
                        if role == .invoice {
                            attachment.amount = metadata.amount ?? 0
                            recognizedAmount = recognizedAmount || metadata.amount != nil
                            if let route = metadata.route { routes.insert(route) }
                            if let times = metadata.railTimes { railTimes.insert(times) }
                        }
                    } else { throw ReimburError("\(source.lastPathComponent) 格式无效，请选择 PDF 或常见图片。") }
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
    func importTripFiles(_ sources: [URL], into claim: Claim, kind: ExpenseKind, naming: AttachmentNaming = .saved(), persist: Bool = true) throws -> Claim {
        guard ready, claim.kind == .trip, claim.kind.categories.contains(kind), kind.acceptsInvoices else {
            throw ReimburError("请选择交通或住宿费用导入发票。")
        }
        guard !sources.isEmpty else { return claim }
        let files = try sources.map { try TripImportRecognition.inspect($0, kind: kind) }
        var updated = claim.withPeopleAssigned.withDirectHotelTotals.withInvoiceLedger
        let originalIDs = Set(claim.attachments.map(\.id))
        var matches: [String: Set<UUID>] = [:]
        func normalizedKey(_ value: String) -> String {
            value.replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression).uppercased()
        }
        func register(_ key: String?, prefix: String, expenseID: UUID) {
            if let key, !key.isEmpty { matches[prefix + normalizedKey(key), default: []].insert(expenseID) }
        }
        for expense in updated.expenses where expense.kind == kind {
            for invoice in expense.invoices { register(invoice.number, prefix: "invoice:", expenseID: expense.id) }
        }
        func emptyRow() -> UUID? {
            updated.expenses.first { $0.kind == kind && $0.attachments.isEmpty && $0.total(in: updated) == 0 &&
                $0.note.isEmpty && $0.origin.isEmpty && $0.destination.isEmpty && $0.dates == nil && $0.departureTime == nil && $0.arrivalTime == nil }?.id
        }
        var importedInvoiceIDs: [UUID] = []
        var fallbackItineraryIndex = 0
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
            let itineraryFallbackIDs = importedInvoiceIDs + updated.expenses
                .filter { $0.kind == kind && !importedInvoiceIDs.contains($0.id) && !$0.invoices.isEmpty }
                .map(\.id)
            for file in files where file.role == .itinerary {
                var candidates = Set<UUID>()
                if let number = file.invoiceNumber { candidates.formUnion(matches["invoice:" + normalizedKey(number)] ?? []) }
                if let order = file.orderNumber { candidates.formUnion(matches["order:" + normalizedKey(order)] ?? []) }
                let expenseID: UUID
                func hasFreeSlot(_ id: UUID) -> Bool {
                    guard let expense = updated.expenses.first(where: { $0.id == id }) else { return false }
                    return (expense.itineraries ?? []).count < max(1, expense.invoices.count)
                }
                let availableCandidates = candidates.filter(hasFreeSlot)
                if availableCandidates.count == 1, let matched = availableCandidates.first { expenseID = matched }
                else if candidates.isEmpty, file.invoiceNumber == nil, file.orderNumber == nil, importedInvoiceIDs.count == 1, hasFreeSlot(importedInvoiceIDs[0]) {
                    expenseID = importedInvoiceIDs[0]
                } else if candidates.isEmpty, file.invoiceNumber == nil, file.orderNumber == nil,
                          let ordered = itineraryFallbackIDs.dropFirst(fallbackItineraryIndex).first(where: hasFreeSlot) {
                    // Some taxi itinerary PDFs contain no stable invoice/order number.
                    // Pair those files with imported invoices in the selection order.
                    expenseID = ordered
                    fallbackItineraryIndex = (itineraryFallbackIDs.firstIndex(of: ordered) ?? fallbackItineraryIndex) + 1
                } else {
                    if let empty = emptyRow() { expenseID = empty }
                    else { updated.addExpense(kind, unitPrice: 0); expenseID = updated.expenses.last!.id }
                    if let index = updated.expenses.firstIndex(where: { $0.id == expenseID }) { updated.expenses[index].note = "行程单（待关联）" }
                }
                updated = try importFiles([file.source], into: updated, expenseID: expenseID, role: .itinerary, naming: naming, persist: false)
            }
            let preferredIDs = Set(updated.attachments.map(\.id)).subtracting(originalIDs)
            let deduplicated = persist
                ? deduplicateInvoiceNumbers(in: updated, preferredIDs: preferredIDs)
                : (updated, [])
            updated = deduplicated.0
            guard !persist || save(updated) else { throw ReimburError(errorMessage ?? "保存导入清单失败。") }
            if persist { deduplicated.1.forEach(discardFile) }
            return updated
        } catch {
            for attachment in updated.attachments where !originalIDs.contains(attachment.id) { discardFile(attachment) }
            throw error
        }
    }

    func chooseTripFiles(for claim: Claim, kind: ExpenseKind) -> Claim? {
        let panel = NSOpenPanel()
        panel.title = "导入"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        do { return try importTripFiles(panel.urls, into: claim, kind: kind) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Imports a mixed batch from the record toolbar. Invoice PDFs are classified locally,
    /// grouped by expense type, and each group creates the corresponding detail rows.
    func chooseAllInvoices(for claim: Claim) -> Claim? {
        var workingClaim = claim
        let controller = ClaimantImportPanelController(names: workingClaim.travelerNames ?? [], kind: claim.kind)
        controller.onUpload = { [weak self, weak controller] claimant in
            guard let self, let controller else { return }
            let panel = NSOpenPanel()
            panel.title = "导入发票"
            panel.allowedContentTypes = [.pdf]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

            var importClaim = workingClaim
            var names = importClaim.travelerNames ?? []
            if !names.contains(claimant) {
                names.append(claimant)
                importClaim.setTravelerNames(names)
            }
            let originalIDs = Set(importClaim.attachments.map(\.id))
            controller.beginProgress()
            do {
                let updated = try self.importAllInvoices(panel.urls, into: importClaim, fallbackKind: nil,
                                                         claimant: claimant, progress: { value in
                    controller.updateProgress(value)
                })
                workingClaim = updated
                controller.setNames(updated.travelerNames ?? [])
                let count = updated.attachments.filter { !originalIDs.contains($0.id) }.count
                controller.completeProgress(message: "成功导入 \(count) 份发票")
            } catch {
                controller.failProgress(message: error.localizedDescription)
            }
        }
        controller.onCancel = {
            NSApp.stopModal(withCode: .cancel)
        }
        // Dim the current app window with an in-window view. Using a separate
        // child NSWindow here can race AppKit's modal-window teardown on macOS.
        let owner = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0 != controller.panel })
        let maskView = NSView(frame: owner?.contentView?.bounds ?? .zero)
        maskView.autoresizingMask = [.width, .height]
        maskView.wantsLayer = true
        maskView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor
        if let contentView = owner?.contentView {
            contentView.addSubview(maskView, positioned: .above, relativeTo: nil)
        }
        controller.panel.orderFront(nil)
        NSApp.runModal(for: controller.panel)
        maskView.removeFromSuperview()
        controller.panel.orderOut(nil)
        return workingClaim == claim ? nil : workingClaim
    }

    func importAllInvoices(_ sources: [URL], into claim: Claim, fallbackKind: ExpenseKind? = nil, claimant: String? = nil, progress: ((Double) -> Void)? = nil) throws -> Claim {
        guard ready else { throw ReimburError("数据库不可用，无法导入发票。") }
        guard !sources.isEmpty else { return claim }
        var updated = claim.withPeopleAssigned.withDirectHotelTotals.withInvoiceLedger.withAllowanceTotal
        let originalIDs = Set(claim.attachments.map(\.id))
        do {
            if claim.kind != .trip {
                let expenseID: UUID
                if let existing = updated.expenses.first(where: { $0.kind == updated.kind.categories[0] }) {
                    expenseID = existing.id
                } else {
                    updated.addExpense(updated.kind.categories[0], unitPrice: 0)
                    expenseID = updated.expenses.last!.id
                }
                progress?(0.35)
                updated = try importFiles(sources, into: updated, expenseID: expenseID, persist: false)
                progress?(0.85)
                if let claimant, let index = updated.expenses.firstIndex(where: { $0.id == expenseID }) {
                    updated.expenses[index].claimant = claimant
                    if var entries = updated.invoiceLedgerEntries {
                        for index in entries.indices where entries[index].expenseID == expenseID { entries[index].claimant = claimant }
                        updated.invoiceLedgerEntries = entries
                    }
                }
            } else {
                var groups: [ExpenseKind: [URL]] = [:]
                for (index, source) in sources.enumerated() {
                    let inspection = try TripImportRecognition.inspect(source)
                    guard let kind = inspection.suggestedKind ?? fallbackKind, kind.acceptsInvoices, claim.kind.categories.contains(kind) else {
                        throw ReimburError("无法识别\(source.lastPathComponent)的费用类型，请在对应费用行上传。")
                    }
                    groups[kind, default: []].append(source)
                    progress?(0.12 + 0.18 * Double(index + 1) / Double(max(1, sources.count)))
                }
                for kind in [ExpenseKind.train, .flight, .taxi, .hotel] where !groups[kind, default: []].isEmpty {
                    progress?(0.35)
                    updated = try importTripFiles(groups[kind] ?? [], into: updated, kind: kind, persist: false)
                    if let claimant {
                        let importedIDs = Set(updated.expenses.filter { $0.kind == kind }.flatMap(\.attachments).map(\.id)).subtracting(originalIDs)
                        for index in updated.expenses.indices where updated.expenses[index].kind == kind && !Set(updated.expenses[index].attachments.map(\.id)).intersection(importedIDs).isEmpty {
                            updated.expenses[index].claimant = claimant
                        }
                        if var entries = updated.invoiceLedgerEntries {
                            let expenseIDs = Set(updated.expenses.filter { $0.kind == kind && !Set($0.attachments.map(\.id)).intersection(importedIDs).isEmpty }.map(\.id))
                            for index in entries.indices where expenseIDs.contains(entries[index].expenseID) { entries[index].claimant = claimant }
                            updated.invoiceLedgerEntries = entries
                        }
                    }
                    progress?(0.35 + 0.55 * Double(updated.expenses.filter { $0.kind == kind }.flatMap(\.attachments).count) / Double(max(1, sources.count)))
                }
            }
            let preferredIDs = Set(updated.attachments.map(\.id)).subtracting(originalIDs)
            let deduplicated = deduplicateInvoiceNumbers(in: updated, preferredIDs: preferredIDs)
            updated = deduplicated.0
            guard save(updated) else { throw ReimburError(errorMessage ?? "保存导入清单失败。") }
            deduplicated.1.forEach(discardFile)
            progress?(1)
            return updated
        } catch {
            for attachment in updated.attachments where !originalIDs.contains(attachment.id) { discardFile(attachment) }
            throw error
        }
    }

    private func deduplicateInvoiceNumbers(in claim: Claim,
                                           preferredIDs: Set<UUID> = [],
                                           preferredExpenseIDs: Set<UUID> = []) -> (Claim, [Attachment]) {
        func key(_ number: String?) -> String? {
            guard let number else { return nil }
            let normalized = number.replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression).uppercased()
            return normalized.isEmpty ? nil : normalized
        }
        struct Occurrence {
            var expenseID: UUID
            var invoiceIndex: Int
            var attachment: Attachment
        }
        var groups: [String: [Occurrence]] = [:]
        for expense in claim.expenses {
            for (index, invoice) in expense.invoices.enumerated() {
                guard let value = key(invoice.number) else { continue }
                groups[value, default: []].append(Occurrence(expenseID: expense.id, invoiceIndex: index, attachment: invoice))
            }
        }
        var updated = claim
        var removed: [Attachment] = []
        for group in groups.values where group.count > 1 && group.contains(where: { preferredIDs.contains($0.attachment.id) }) {
            let anchor = group.first { preferredExpenseIDs.contains($0.expenseID) }
                ?? group.first { !preferredIDs.contains($0.attachment.id) }
                ?? group[0]
            let winner = group.last { preferredIDs.contains($0.attachment.id) } ?? group[group.count - 1]
            guard let targetIndex = updated.expenses.firstIndex(where: { $0.id == anchor.expenseID }) else { continue }
            let winnerExpense = updated.expenses.first { $0.id == winner.expenseID }
            let duplicateIDs = Set(group.map(\.attachment.id))
            let entries = updated.invoiceLedgerEntries ?? []
            let anchorEntryIndex = entries.firstIndex { duplicateIDs.contains($0.invoiceID ?? UUID()) }
            let entryTemplate = anchorEntryIndex.map { entries[$0] }
                ?? entries.last { winner.attachment.id == $0.invoiceID }

            for index in updated.expenses.indices {
                updated.expenses[index].invoices.removeAll { duplicateIDs.contains($0.id) }
            }
            var target = updated.expenses[targetIndex]
            let insertionIndex = min(anchor.invoiceIndex, target.invoices.count)
            target.invoices.insert(winner.attachment, at: insertionIndex)
            if let claimant = winnerExpense?.claimant { target.claimant = claimant }
            if target.origin.isEmpty, let origin = winnerExpense?.origin { target.origin = origin }
            if target.destination.isEmpty, let destination = winnerExpense?.destination { target.destination = destination }
            if target.departureTime == nil { target.departureTime = winnerExpense?.departureTime }
            if target.arrivalTime == nil { target.arrivalTime = winnerExpense?.arrivalTime }
            if target.synchronizesInvoiceTotal { target.setTotalAmount(target.invoiceTotal) }
            updated.expenses[targetIndex] = target

            if var rows = updated.invoiceLedgerEntries {
                rows.removeAll { duplicateIDs.contains($0.invoiceID ?? UUID()) }
                if var entry = entryTemplate {
                    entry.expenseID = target.id
                    entry.invoiceID = winner.attachment.id
                    entry.reimbursementAmount = winner.attachment.amount
                    rows.insert(entry, at: min(anchorEntryIndex ?? rows.count, rows.count))
                }
                updated.invoiceLedgerEntries = rows
            }
            removed += group.compactMap { $0.attachment.id == winner.attachment.id ? nil : $0.attachment }

            let occurrenceExpenseIDs = Set(group.map(\.expenseID)).subtracting([target.id])
            let removableExpenses = occurrenceExpenseIDs.filter { id in
                updated.expenses.first { $0.id == id }?.attachments.isEmpty == true
            }
            if !removableExpenses.isEmpty {
                updated.expenses.removeAll { removableExpenses.contains($0.id) }
                updated.invoiceLedgerEntries?.removeAll { removableExpenses.contains($0.expenseID) }
            }
        }
        return (updated, removed)
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
        guard let row = claim.invoiceLedgerEntries?.first(where: { $0.id == id }),
              let expenseIndex = claim.expenses.firstIndex(where: { $0.id == row.expenseID }) else { return nil }
        var updated = claim
        let expense = updated.expenses[expenseIndex]
        let invoice = expense.invoices.first { $0.id == row.invoiceID }
        updated.invoiceLedgerEntries?.removeAll { $0.id == id }
        updated.expenses[expenseIndex].invoices.removeAll { $0.id == row.invoiceID }

        var removed = invoice.map { [$0] } ?? []
        if updated.expenses[expenseIndex].invoices.isEmpty {
            removed += updated.expenses[expenseIndex].attachments
            let expenseID = updated.expenses[expenseIndex].id
            updated.expenses.remove(at: expenseIndex)
            updated.invoiceLedgerEntries?.removeAll { $0.expenseID == expenseID }
        } else if updated.expenses[expenseIndex].synchronizesInvoiceTotal {
            updated.expenses[expenseIndex].synchronizeInvoiceTotal()
        }
        guard save(updated) else { return nil }
        var discarded = Set<UUID>()
        for attachment in removed where discarded.insert(attachment.id).inserted { discardFile(attachment) }
        return updated.withPeopleAssigned
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

    func replaceExpenseAttachment(_ existing: Attachment?, in claim: Claim, expenseID: UUID,
                                  role: ExpenseAttachmentRole, with source: URL) throws -> Claim {
        guard let expenseIndex = claim.expenses.firstIndex(where: { $0.id == expenseID }) else {
            throw ReimburError("费用项目已不存在。")
        }
        let originalIDs = Set(claim.attachments.map(\.id))
        let oldAttachments = role == .invoice ? claim.expenses[expenseIndex].invoices : (claim.expenses[expenseIndex].itineraries ?? [])
        let oldIDs = Set(oldAttachments.map(\.id))
        let oldEntryIndex = claim.invoiceLedgerEntries?.firstIndex { oldIDs.contains($0.invoiceID ?? UUID()) }
        let oldEntry = oldEntryIndex.flatMap { claim.invoiceLedgerEntries?[$0] }
        var base = claim
        if role == .invoice {
            base.expenses[expenseIndex].invoices.removeAll { oldIDs.contains($0.id) }
            base.invoiceLedgerEntries?.removeAll { oldIDs.contains($0.invoiceID ?? UUID()) }
        } else {
            base.expenses[expenseIndex].itineraries?.removeAll { oldIDs.contains($0.id) }
        }

        var added: Attachment?
        do {
            var updated = try importFiles([source], into: base, expenseID: expenseID, role: role, persist: false)
            guard let updatedIndex = updated.expenses.firstIndex(where: { $0.id == expenseID }) else {
                throw ReimburError("费用项目已不存在。")
            }
            let newAttachments = updated.attachments.filter { !originalIDs.contains($0.id) && !oldIDs.contains($0.id) }
            guard let newest = role == .invoice
                    ? updated.expenses[updatedIndex].invoices.last
                    : updated.expenses[updatedIndex].itineraries?.last,
                  newAttachments.contains(where: { $0.id == newest.id }) else {
                throw ReimburError(role == .invoice ? "上传发票失败。" : "上传行程单失败。")
            }
            added = newest
            if role == .invoice, var entry = oldEntry, var rows = updated.invoiceLedgerEntries {
                rows.removeAll { $0.invoiceID == newest.id }
                entry.expenseID = expenseID
                entry.invoiceID = newest.id
                entry.reimbursementAmount = newest.amount
                rows.insert(entry, at: min(oldEntryIndex ?? rows.count, rows.count))
                updated.invoiceLedgerEntries = rows
            }
            let deduplicated = deduplicateInvoiceNumbers(in: updated, preferredIDs: [newest.id],
                                                          preferredExpenseIDs: [expenseID])
            updated = deduplicated.0
            guard save(updated) else { throw ReimburError(errorMessage ?? "保存附件失败。") }
            var discarded = Set<UUID>()
            for attachment in oldAttachments + deduplicated.1 where discarded.insert(attachment.id).inserted {
                if attachment.id != newest.id { discardFile(attachment) }
            }
            return updated
        } catch {
            if let added { discardFile(added) }
            throw error
        }
    }

    func chooseFiles(for claim: Claim, expenseID: UUID?, role: ExpenseAttachmentRole = .invoice) -> Claim? {
        let panel = NSOpenPanel()
        panel.title = expenseID == nil ? "上传报销单图片" : role == .itinerary ? "上传打车行程单" : "上传 PDF 发票"
        panel.allowedContentTypes = expenseID == nil ? [.png, .jpeg, .heic, .tiff, .bmp, .gif] : role == .itinerary ? [.pdf, .png, .jpeg, .heic, .tiff, .bmp, .gif] : [.pdf]
        panel.allowsMultipleSelection = expenseID == nil
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        do {
            if let expenseID, let source = panel.url {
                let existing = role == .invoice
                    ? claim.expenses.first { $0.id == expenseID }?.invoices.first
                    : claim.expenses.first { $0.id == expenseID }?.itineraries?.first
                return try replaceExpenseAttachment(existing, in: claim, expenseID: expenseID, role: role, with: source)
            }
            return try importFiles(panel.urls, into: claim, expenseID: expenseID, role: role)
        }
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
