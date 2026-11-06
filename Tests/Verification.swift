import AppKit
import PDFKit
import SwiftUI

private final class TestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        super.makeKeyAndOrderFront(sender)
        makeKey()
        makeMain()
    }
}

@MainActor private final class InteractionState: ObservableObject {
    @Published var dates: Set<String> = ["2026-10-01"]
    @Published var names: [String] = []
}
@MainActor private final class TabInteractionState: ObservableObject {
    @Published var claim: Claim = {
        var claim = Claim.make(.trip)
        claim.expenses += [Expense(kind: .train, unitPrice: 100), Expense(kind: .taxi, unitPrice: 200)]
        return claim
    }()
    @Published var selection: ExpenseKind? = .subsidy
}
private struct TabInteractionView: View {
    @ObservedObject var state: TabInteractionState
    var body: some View { ExpenseGroupTabs(claim: $state.claim, selection: $state.selection).padding(20) }
}
private struct InteractionView: View {
    @ObservedObject var state: InteractionState
    var body: some View {
        HStack {
            PeopleTagInput(names: $state.names).frame(width: 300, height: 300)
            CalendarPicker(selection: $state.dates).frame(width: 270)
        }.padding(30)
    }
}

@MainActor private final class AttachmentNameState: ObservableObject {
    @Published var attachment: Attachment
    init(_ attachment: Attachment) { self.attachment = attachment }
}
private struct AttachmentNameInteractionView: View {
    @ObservedObject var state: AttachmentNameState
    var rename: (String) -> Void
    var body: some View { EditableAttachmentName(attachment: state.attachment, rename: rename).padding(20).frame(width: 500, height: 80).background(.white) }
}

@MainActor private final class LedgerDateState: ObservableObject {
    @Published var value = "2026-08-24"
}
private struct LedgerDateInteractionView: View {
    @ObservedObject var state: LedgerDateState
    var body: some View { LedgerDateField(value: $state.value).frame(width: 122).padding(20).background(.white) }
}

@MainActor private final class TripListState: ObservableObject {
    @Published var claim: Claim
    init(_ claim: Claim) { self.claim = claim }
}
private struct TripListInteractionView: View {
    @ObservedObject var state: TripListState
    var store: ClaimStore
    var body: some View {
        TripExpenseListView(claim: $state.claim, kind: .train, remove: { _ in }, files: verificationFileActions(state, store))
            .padding(20).background(.white).onChange(of: state.claim) { _, value in _ = store.save(value) }
    }
}

private struct AdjustableTripInteractionView: View {
    @ObservedObject var state: TripListState
    var store: ClaimStore
    var kind: ExpenseKind
    var body: some View {
        TripExpenseListView(claim: $state.claim, kind: kind, remove: { id in state.claim.expenses.removeAll { $0.id == id } }, files: verificationFileActions(state, store))
            .padding(20).background(.white).onChange(of: state.claim) { _, value in _ = store.save(value) }
    }
}

private struct TripAttachmentsInteractionView: View {
    @ObservedObject var state: TripListState
    var store: ClaimStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card { TripExpenseListView(claim: $state.claim, kind: .taxi, remove: { _ in }, files: verificationFileActions(state, store)) }
            Spacer(minLength: 0)
        }.padding(20).background(Palette.canvas).onChange(of: state.claim) { _, value in _ = store.save(value) }
    }
}

private struct InlineLedgerInteractionView: View {
    @ObservedObject var state: TripListState
    var store: ClaimStore
    var body: some View {
        InvoiceLedgerView(claim: $state.claim, export: {}, files: verificationFileActions(state, store))
            .padding(20).background(Palette.canvas).onChange(of: state.claim) { _, value in _ = store.save(value) }
    }
}

private struct SubsidyListInteractionView: View {
    @ObservedObject var state: TripListState
    var body: some View {
        TripExpenseListView(claim: $state.claim, kind: .subsidy, remove: { _ in }).padding(20).background(.white)
    }
}

@MainActor private func verificationFileActions(_ state: TripListState, _ store: ClaimStore) -> ExpenseFileActions {
    ExpenseFileActions(open: { store.previewAttachment($0, in: state.claim) }, hover: { store.hoverAttachment($0, location: $1) }, rename: { attachment, name, id in
        if let value = try? store.renameAttachment(attachment, to: name, in: state.claim, expenseID: id) { state.claim = value }
    }, remove: { attachment, id in
        if let value = store.removeAttachment(attachment, from: state.claim, expenseID: id) { state.claim = value }
    }, move: { attachment, source, destination in
        if let value = store.moveItinerary(attachment, in: state.claim, from: source, to: destination) { state.claim = value }
    }, duplicateExpense: { id in
        if let value = try? store.duplicateExpense(id, in: state.claim) { state.claim = value }
    }, duplicateLedgerRow: { id in
        if let value = try? store.duplicateLedgerRow(id, in: state.claim) { state.claim = value }
    }, removeLedgerRow: { id in
        if let value = store.removeLedgerRow(id, in: state.claim) { state.claim = value }
    })
}

final class ReimburChecks {
    private var temporary: URL!
    func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Reimbur-tests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    @MainActor func testGlobalPreviewsAndCloseButtons() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let suite = "Reimbur-global-previews-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defaults.set("records", forKey: "startupPage")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        let claim = tripFormFixture(); expectTrue(store.save(claim))
        let file = claim.expenses[0].invoices[0]
        try FileManager.default.createDirectory(at: store.url(for: file).deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeTripImportPDF(store.url(for: file), lines: ["演示发票", "金额 ¥69.00"])
        let view = WorkspaceView().environmentObject(store).defaultAppStorage(defaults).preferredColorScheme(.light).tint(Palette.accent)
        try captureView(view, width: 1440, height: 1000, to: qa.appendingPathComponent("global-preview-closed.png")) { window, host in
            @MainActor func snapshot(_ name: String) {
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: qa.appendingPathComponent(name))
            }
            @MainActor func listBrightness() -> CGFloat {
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return bitmap.colorAt(x: 580, y: 100)!.usingColorSpace(.deviceRGB)!.redComponent
            }
            let before = listBrightness()
            store.previewTripForm(claim); pumpNativeEvents(0.5)
            guard let pdf = verificationViews(host, FormPDFView.self).first else { fail("Global trip form missing"); return }
            let formFrame = host.convert(pdf.bounds, from: pdf)
            expectTrue(abs(formFrame.midX - host.bounds.midX) < 2)
            expectTrue(listBrightness() < before - 0.2)
            snapshot("global-trip-form.png")
            nativeClick(NSPoint(x: 1190, y: host.isFlipped ? 160 : 840), in: host, window: window)
            expectNil(store.recordPreview)
            expectTrue(verificationViews(host, FormPDFView.self).isEmpty)
            store.previewSummary(claim, personID: claim.personBreakdowns[0].id); pumpNativeEvents(0.4)
            expectTrue(listBrightness() < before - 0.2)
            snapshot("global-person-summary.png")
            nativeClick(NSPoint(x: 1190, y: host.isFlipped ? 160 : 840), in: host, window: window)
            expectNil(store.recordPreview)
            store.previewAttachment(file, in: claim); pumpNativeEvents(0.4)
            guard let canvas = verificationViews(host, AttachmentCanvasView.self).first else { fail("Global attachment missing"); return }
            expectTrue(abs(host.convert(canvas.bounds, from: canvas).midX - host.bounds.midX) < 2)
            snapshot("global-attachment.png")
            nativeClick(NSPoint(x: 1190, y: host.isFlipped ? 160 : 840), in: host, window: window)
            expectNil(store.preview)
            store.previewTripForm(claim); pumpNativeEvents()
            nativeClick(NSPoint(x: 90, y: host.isFlipped ? 350 : 650), in: host, window: window)
            expectNil(store.recordPreview) // Clicking the left menu area closes the global mask.
            expectTrue(listBrightness() > before - 0.05)
        }
    }

    @MainActor func testSelectableTripFormZoomPanAndCopy() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let claim = tripFormFixture(), data = TripFormData(claim: tripFormFixture())
        let document = TripFormPDF.document(data)!
        expectEqual(document.pageCount, 1)
        expectTrue(document.string?.contains("软件部") == true)
        expectTrue(document.string?.contains("1072.31") == true)
        expectTrue(document.page(at: 0)!.numberOfCharacters > 100)
        try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
        document.write(to: qa.appendingPathComponent("selectable-trip-form.pdf"))
        let originalCursor = NSEvent.mouseLocation
        defer { CGWarpMouseCursorPosition(CGPoint(x: originalCursor.x, y: NSScreen.screens[0].frame.maxY - originalCursor.y)) }
        try captureView(TripFormPreview(claim: claim).background(Palette.canvas).tint(Palette.accent), width: 1000, height: 740,
                        to: qa.appendingPathComponent("selectable-form-preview.png")) { window, host in
            guard let pdf = verificationViews(host, FormPDFView.self).first, let page = pdf.document?.page(at: 0),
                  let word = pdf.document?.findString("软件部", withOptions: []).first else { fail("Selectable PDF text missing"); return }
            let rect = word.bounds(for: page)
            let start = pdf.convert(NSPoint(x: rect.minX + 1, y: rect.midY), from: page)
            let end = pdf.convert(NSPoint(x: rect.maxX - 1, y: rect.midY), from: page)
            nativeDrag(from: start, to: end, in: pdf, window: window)
            expectTrue(pdf.currentSelection?.string?.contains("软件") == true)
            pdf.copy(nil)
            expectTrue(NSPasteboard.general.string(forType: .string)?.contains("软件") == true)
            let scale = pdf.scaleFactor
            let center = NSPoint(x: pdf.bounds.midX, y: pdf.bounds.midY)
            verificationMovePointer(center, in: pdf, window: window)
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0)!
            let screen = window.convertPoint(toScreen: pdf.convert(center, to: nil))
            scroll.location = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y)
            pdf.scrollWheel(with: NSEvent(cgEvent: scroll)!); pumpNativeEvents(0.3)
            expectTrue(abs(pdf.scaleFactor - scale) > 0.01)
            pdf.zoom(by: 2.5, around: center); pumpNativeEvents()
            let before = pdf.pan
            for type in [NSEvent.EventType.keyDown] {
                let key = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                NSApplication.shared.postEvent(key, atStart: false)
            }
            pumpNativeEvents()
            nativeDrag(from: center, to: NSPoint(x: center.x - 70, y: center.y - 40), in: pdf, window: window)
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
            NSApplication.shared.postEvent(up, atStart: false); pumpNativeEvents()
            expectTrue(hypot(pdf.pan.x - before.x, pdf.pan.y - before.y) > 10)
            pdf.fitDocument(); pumpNativeEvents()
            expectTrue(abs(pdf.scaleFactor - scale) < 0.02)
        }
    }

    @MainActor func testNativeInvoiceHoverPreviewFollowsAndDismisses() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip); claim.setTravelerNames(["张三"]); claim.expenses = []
        claim.addExpense(.taxi, unitPrice: 0)
        let source = temporary.appendingPathComponent("演示发票.pdf"), itinerary = temporary.appendingPathComponent("演示行程单.pdf")
        try makeTripImportPDF(source, lines: ["电子发票（普通发票）", "发票号码：12345678901234567890", "价税合计 ¥38.00"])
        try makeTripImportPDF(itinerary, lines: ["打车行程单", "发票号码：12345678901234567890", "杭州至宁波"])
        claim = try store.importTripFiles([source, itinerary], into: claim, kind: .taxi)
        let file = claim.expenses[0].invoices[0], trip = claim.expenses[0].itineraries![0]
        let state = TripListState(claim)
        let originalCursor = NSEvent.mouseLocation
        defer { CGWarpMouseCursorPosition(CGPoint(x: originalCursor.x, y: NSScreen.screens[0].frame.maxY - originalCursor.y)) }
        let view = TripAttachmentsInteractionView(state: state, store: store).overlay { WorkspacePreviewLayer().environmentObject(store) }.tint(Palette.accent)
        try captureView(view, width: 1250, height: 620, to: qa.appendingPathComponent("invoice-hover.png")) { window, host in
            let trackers = verificationViews(host, AttachmentHoverTrackingView.self).sorted { host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX }
            expectEqual(trackers.count, 2)
            guard let first = trackers.first, let last = trackers.last else { return }
            let a = host.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), from: first)
            verificationMovePointer(a, in: host, window: window); pumpNativeEvents(0.8)
            expectEqual(store.hoverPreview.request?.attachment.id, file.id)
            expectTrue(store.hoverPreview.visible)
            expectTrue(store.hoverPreview.image?.isValid == true)
            guard let canvas = verificationViews(host, AttachmentHoverCanvasView.self).first, let firstFrame = canvas.cardFrame else { fail("Hover canvas not visible"); return }
            verificationMovePointer(NSPoint(x: a.x + 12, y: a.y + 5), in: host, window: window)
            if let moved = canvas.cardFrame {
                expectTrue(abs(moved.minX - firstFrame.minX - 12) < 2)
                expectTrue(abs(moved.minY - firstFrame.minY - (host.isFlipped ? 5 : -5)) < 2)
            } else { fail("Moving pointer lost preview") }
            verificationMovePointer(NSPoint(x: 10, y: 10), in: host, window: window)
            expectFalse(store.hoverPreview.visible)
            let b = host.convert(NSPoint(x: last.bounds.midX, y: last.bounds.midY), from: last)
            verificationMovePointer(a, in: host, window: window)
            verificationMovePointer(b, in: host, window: window); pumpNativeEvents(0.7)
            expectEqual(store.hoverPreview.request?.attachment.id, trip.id)
            expectTrue(store.hoverPreview.visible)
            store.previewAttachment(file, in: claim); pumpNativeEvents()
            expectNil(store.hoverPreview.request)
            store.hoverAttachment(trip, location: b)
            expectNil(store.hoverPreview.request)
            store.dismissPreview()
            verificationMovePointer(NSPoint(x: 10, y: 10), in: host, window: window)
            verificationMovePointer(a, in: host, window: window); pumpNativeEvents(0.5)
            expectTrue(store.hoverPreview.visible)
        }
        let bounds = CGRect(x: 0, y: 0, width: 1250, height: 620), size = CGSize(width: 320, height: 372)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1248, y: 0), CGPoint(x: 1248, y: 618), CGPoint(x: 0, y: 618)] {
            let frame = AttachmentHoverPlacement.frame(cursor: point, size: size, bounds: bounds)
            expectTrue(bounds.insetBy(dx: 7, dy: 7).contains(frame))
            expectFalse(frame.contains(point))
        }
    }

    @MainActor func testZoomedPreviewsStayInsideViewport() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let marker = NSImage(size: NSSize(width: 600, height: 900), flipped: false) { rect in
            NSColor.systemPink.setFill(); rect.fill(); return true
        }
        let png = temporary.appendingPathComponent("预览边界.png")
        let bitmap = NSBitmapImageRep(data: marker.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let pdf = PDFDocument(); pdf.insert(PDFPage(image: marker)!, at: 0)
        let pdfURL = temporary.appendingPathComponent("预览边界.pdf"); expectTrue(pdf.write(to: pdfURL))
        @MainActor func capture(_ host: NSView) -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap); return bitmap
        }
        @MainActor func expectSameHeader(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep) {
            var changed = 0
            for x in stride(from: 20, to: before.pixelsWide - 20, by: 10) {
                for y in stride(from: 10, to: min(48, before.pixelsHigh), by: 5) {
                    let a = before.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let b = after.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.08 { changed += 1 }
                }
            }
            expectEqual(changed, 0)
        }
        for source in [png, pdfURL] {
            let request = PreviewRequest(attachment: Attachment(name: source.lastPathComponent, storedName: source.lastPathComponent), url: source)
            try captureView(AttachmentPreview(request: request).tint(Palette.accent), width: 1000, height: 740,
                            to: qa.appendingPathComponent("bounded-\(source.pathExtension)-preview.png")) { window, host in
                guard let canvas = verificationViews(host, AttachmentCanvasView.self).first else { fail("Attachment canvas missing"); return }
                let before = capture(host)
                let center = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
                canvas.zoom(by: 8, around: center); pumpNativeEvents()
                expectTrue(canvas.imageRect.width > canvas.bounds.width)
                expectTrue(canvas.imageRect.height > canvas.bounds.height)
                nativeDrag(from: center, to: NSPoint(x: center.x + 140, y: center.y + 100), in: canvas, window: window)
                expectSameHeader(before, capture(host))
            }
        }
        try captureView(TripFormPreview(claim: tripFormFixture()).background(Palette.canvas), width: 1000, height: 740,
                        to: qa.appendingPathComponent("bounded-form-preview.png")) { window, host in
            guard let canvas = verificationViews(host, FormPDFView.self).first else { fail("Form canvas missing"); return }
            let before = capture(host), center = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            canvas.zoom(by: 8, around: center); pumpNativeEvents()
            expectTrue(canvas.pageRect.width > canvas.bounds.width)
            expectSameHeader(before, capture(host))
        }
    }

    @MainActor func testManualRouteTextIsPreserved() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("manual-route-db"))
        var claim = Claim.make(.trip); claim.setTravelerNames(["张三"])
        claim.expenses = [Expense(kind: .train, origin: "杭州东", destination: "宁波", claimant: "张三")]
        expectTrue(store.save(claim))
        let state = TripListState(claim)
        let origin = "杭州东站", destination = " 宁波南站 · 自定义地点 "
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try captureView(TripListInteractionView(state: state, store: store).tint(Palette.accent), width: 1550, height: 260,
                        to: qa.appendingPathComponent("manual-route-text.png")) { _, host in
            for (old, value) in [("杭州", origin), ("宁波", destination)] {
                guard let picker = verificationViews(host, NSPopUpButton.self).first(where: { $0.titleOfSelectedItem == old }) else { fail("Route picker missing"); return }
                picker.selectItem(withTitle: "手动输入…")
                picker.sendAction(picker.action!, to: picker.target); pumpNativeEvents(0.3)
                let field = NSApplication.shared.windows.filter(\.isVisible).compactMap(\.contentView)
                    .flatMap { verificationViews($0, NSTextField.self) }.first { $0.placeholderString == "输入地点" }
                guard let field, let editor = field.currentEditor() as? NSTextView, let window = field.window else { fail("Custom route input not focused"); return }
                editor.selectAll(nil); editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
                let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                window.sendEvent(enter); pumpNativeEvents(0.3)
                expectTrue(verificationViews(host, NSPopUpButton.self).contains { $0.titleOfSelectedItem == value })
            }
            expectEqual(state.claim.expenses[0].originCity, origin)
            expectEqual(state.claim.expenses[0].destinationCity, destination)
        }
        claim = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
        expectEqual(claim.expenses[0].origin, origin)
        expectEqual(claim.expenses[0].originCity, origin)
        expectEqual(claim.expenses[0].destinationCity, destination)
        expectTrue(ClaimSummary.renderOverview(claim).contains(origin + "-" + destination))
        let paper = TripFormPaper(data: TripFormData(claim: claim))
        expectTrue(paper.cells.contains { $0.text == origin })
        expectTrue(paper.cells.contains { $0.text == destination })
        expectTrue(TripFormPDF.document(TripFormData(claim: claim))?.string?.contains(origin) == true)
        // Updating an invoice must not overwrite either manually edited place.
        let source = temporary.appendingPathComponent("再次导入车票.pdf")
        try makeTripImportPDF(source, lines: ["电子发票（铁路电子客票）", "发票号码：12345678901234567890", "出发站：上海虹桥", "到达站：济南西站", "票价 ¥69.00"])
        claim = try store.importFiles([source], into: claim, expenseID: claim.expenses[0].id)
        expectEqual(claim.expenses[0].originCity, origin)
        expectEqual(claim.expenses[0].destinationCity, destination)
        let saved = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
        expectEqual(saved.expenses[0].originCity, origin)
        expectEqual(saved.expenses[0].destinationCity, destination)
        var oneSide = Expense(kind: .train)
        oneSide.originCity = "自填起点"
        oneSide.applyRecognizedRailRoute(RailRoute(origin: "上海虹桥", destination: "杭州西站"))
        expectEqual(oneSide.originCity, "自填起点")
        expectEqual(oneSide.destinationCity, "杭州")
    }

    @MainActor func testRailCitiesInListsFormsAndImports() throws {
        for (station, city) in [("杭州东站", "杭州"), ("杭州西站", "杭州"), ("宁波站", "宁波"),
                                (" 上海虹桥火车站 ", "上海"), ("北京南", "北京"), ("济南西站", "济南"),
                                ("淮南东", "淮南"), ("济南", "济南"), ("淮北", "淮北"), ("呼和浩特东", "呼和浩特"),
                                ("汉口", "武汉"), ("", ""), ("苏州园区", "苏州"), ("黔东南", "黔东南"), ("未知地点", "未知地点")] {
            expectEqual(RailCity.name(station), city)
        }
        var claim = Claim.make(.trip); claim.setTravelerNames(["张三"])
        claim.expenses = [Expense(kind: .train, unitPrice: 6900, origin: "杭州东站", destination: "宁波站", claimant: "张三"),
                          Expense(kind: .train, unitPrice: 8500, origin: "杭州西站", destination: "宁波站", claimant: "张三")]
        let store = ClaimStore(root: temporary.appendingPathComponent("city-db"))
        expectTrue(store.save(claim))
        let legacy = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
        expectEqual(legacy.expenses[0].origin, "杭州东站")
        expectEqual(legacy.expenses[0].originCity, "杭州")
        expectTrue(ClaimSummary.renderOverview(legacy).contains("杭州-宁波：69.00+85.00=154.00"))
        let data = TripFormData(claim: legacy)
        let paper = TripFormPaper(data: data)
        expectFalse(paper.cells.contains { $0.text == "杭州东站" || $0.text == "杭州西站" || $0.text == "宁波站" })
        expectTrue(paper.cells.contains { $0.text == "杭州" })
        let pdf = TripFormPDF.document(data)
        expectTrue(pdf?.string?.contains("杭州") == true)
        expectFalse(pdf?.string?.contains("杭州东站") == true)
        let state = TripListState(legacy)
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try captureView(TripListInteractionView(state: state, store: store).tint(Palette.accent), width: 1550, height: 330,
                        to: qa.appendingPathComponent("train-cities.png")) { _, host in
            let titles = verificationViews(host, NSPopUpButton.self).compactMap(\.titleOfSelectedItem)
            expectEqual(titles.filter { $0 == "杭州" }.count, 2)
            expectEqual(titles.filter { $0 == "宁波" }.count, 2)
            expectFalse(titles.contains("杭州东站"))
        }
        let source = temporary.appendingPathComponent("城市车票.pdf")
        try makeTripImportPDF(source, lines: ["电子发票（铁路电子客票）", "发票号码：12345678901234567890", "出发站：杭州西站", "到达站：宁波站", "票价 ¥69.00"])
        claim = try store.importTripFiles([source], into: claim, kind: .train)
        let imported = claim.expenses.last { !$0.invoices.isEmpty }!
        expectEqual(imported.origin, "杭州")
        expectEqual(imported.destination, "宁波")
        expectEqual(ClaimStore(root: store.root).claims.first { $0.id == claim.id }?.expenses.last?.originCity, "杭州")
        var edited = imported; edited.originCity = "杭州东站"; edited.destinationCity = "济南西站"
        expectEqual(edited.originCity, "杭州东站"); expectEqual(edited.destinationCity, "济南西站")
    }

    @MainActor func testRailArrivalDateDefaultsAndOverrides() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip); claim.setTravelerNames(["张三"])
        let source = temporary.appendingPathComponent("火车票.pdf")
        try makeTripImportPDF(source, lines: ["电子发票（铁路电子客票）", "发票号码：12345678901234567890", "出发站：杭州东", "到达站：宁波", "乘车日期：2026-11-02 08:30", "票价 ¥69.00"])
        claim = try store.importTripFiles([source], into: claim, kind: .train)
        let index = claim.expenses.firstIndex { $0.kind == .train }!
        expectNil(claim.expenses[index].arrivalTime)
        expectEqual(claim.expenses[index].effectiveArrivalDate, "2026-11-02")
        claim.expenses[index].departureTime = "2026-11-03"
        expectTrue(store.save(claim))
        claim = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
        expectEqual(claim.expenses[index].effectiveArrivalDate, "2026-11-03")
        var overnight = claim.expenses[index]; overnight.id = UUID()
        overnight.arrivalTime = "2026-11-04"
        claim.expenses.insert(overnight, at: index)
        claim.sortExpenses(.train, column: "arrival", ascending: true)
        let rows = claim.expenses.filter { $0.kind == .train }
        expectEqual(rows.map(\.effectiveArrivalDate), ["2026-11-03", "2026-11-04"])
        expectTrue(store.save(claim))
        claim = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
        let explicit = claim.expenses.firstIndex { $0.id == overnight.id }!
        claim.expenses[explicit].departureTime = "2026-11-02"
        expectEqual(claim.expenses[explicit].effectiveArrivalDate, "2026-11-04")
        expectEqual(TripFormData.momentParts(claim.expenses[explicit].effectiveArrivalDate, place: "宁波"), ["11", "4", "", "宁波"])
        if let path = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let state = TripListState(claim)
            try captureView(TripListInteractionView(state: state, store: store).tint(Palette.accent), width: 1550, height: 300,
                            to: URL(fileURLWithPath: path).appendingPathComponent("train-arrival-default.png"))
        }
        claim.expenses[explicit].arrivalTime = nil
        expectTrue(store.save(claim))
        expectEqual(ClaimStore(root: store.root).claims.first { $0.id == claim.id }?.expenses.first { $0.id == overnight.id }?.effectiveArrivalDate, "2026-11-02")
        var missing = Expense(kind: .train)
        expectNil(missing.effectiveArrivalDate)
        missing.departureTime = "2026-11-02 18:30"
        expectEqual(missing.effectiveArrivalDate, "2026-11-02")
        missing.kind = .flight
        expectNil(missing.effectiveArrivalDate)
    }

    @MainActor func testRailTimesDefaultsAndPersistence() throws {
        expectEqual(RailTimes.recognize("开票日期：2026-11-02\n乘车日期：2026年10月7日\n开车时间：08:30\n到达时间：2026-10-07 10:35"), RailTimes(departure: "2026-10-07", arrival: "2026-10-07"))
        expectEqual(RailTimes.recognize("2026年10月07日 08:30开"), RailTimes(departure: "2026-10-07", arrival: nil))
        expectEqual(RailTimes.recognize("乘车日期：2026-10-07"), RailTimes(departure: "2026-10-07", arrival: nil))
        expectNil(RailTimes.recognize("开票日期：2026-11-02 12:30\n出发地：杭州东\n目的地：宁波"))
        expectNil(RailTimes.recognize("出发日期：2026-02-30"))
        expectNil(RailMoment.date("2026-10-07 25:30"))
        let suite = "Reimbur-trip-defaults-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("软件部", forKey: "defaultDepartment"); defaults.set("制造项目现场实施", forKey: "defaultTripPurpose")
        defaults.set(AppPreferences.encodeNames(["张三"]), forKey: "defaultTravelerNames")
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        let id = store.create(.trip, defaults: ExpenseDefaults.saved(in: defaults))!
        var claim = store.claims.first { $0.id == id }!
        expectEqual(claim.department, "软件部"); expectEqual(claim.tripPurpose, "制造项目现场实施")
        defaults.set("测试部", forKey: "defaultDepartment")
        expectEqual(store.claims.first { $0.id == id }?.department, "软件部")
        var files: [URL] = []
        for (index, day) in ["2026-10-09", "2026-10-07"].enumerated() {
            let source = temporary.appendingPathComponent("车票\(index).pdf")
            try makeTripImportPDF(source, lines: ["电子发票（铁路电子客票）", "发票号码：1234567890123456789\(index)", "出发站：杭州东", "到达站：宁波", "乘车日期：\(day) 08:30", "到达时间：\(day) 10:35", "票价 ¥69.00"])
            files.append(source)
        }
        claim = try store.importTripFiles(files, into: claim, kind: .train)
        let rows = RailMoment.ordered(claim.expenses.filter { $0.kind == .train })
        expectEqual(rows.map(\.departureTime), ["2026-10-07", "2026-10-09"])
        expectEqual(rows.map(\.arrivalTime), ["2026-10-07", "2026-10-09"])
        expectTrue(rows.allSatisfy { $0.origin == "杭州" && $0.destination == "宁波" && $0.invoiceTotal == 6900 })
        var unknown = Expense(kind: .train); unknown.origin = "未填时间"
        expectEqual(RailMoment.ordered([unknown] + rows.reversed()).last?.id, unknown.id)
        var late = rows[0], early = rows[0]; early.id = UUID()
        late.departureTime = "2026-10-07 18:00"; early.departureTime = "2026-10-07 08:00"
        expectEqual(RailMoment.dayKey(late.departureTime), "2026-10-07")
        expectEqual(RailMoment.ordered([late, early]).map(\.id), [late.id, early.id])
        expectEqual(TripFormData.momentParts(late.departureTime, place: "宁波"), ["10", "7", "", "宁波"])
        let restored = ClaimStore(root: store.root).claims.first { $0.id == id }!
        expectEqual(restored.department, claim.department); expectEqual(restored.tripPurpose, claim.tripPurpose)
        expectEqual(restored.expenses, claim.expenses)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(claim)) as! [String: Any]
        json.removeValue(forKey: "department"); json.removeValue(forKey: "tripPurpose")
        json["expenses"] = (json["expenses"] as! [[String: Any]]).map { item in
            var item = item; item.removeValue(forKey: "departureTime"); item.removeValue(forKey: "arrivalTime"); return item
        }
        let legacy = try JSONDecoder().decode(Claim.self, from: JSONSerialization.data(withJSONObject: json))
        expectNil(legacy.department); expectNil(legacy.tripPurpose)
        expectTrue(legacy.expenses.allSatisfy { $0.departureTime == nil && $0.arrivalTime == nil })
    }

    private func tripFormFixture() -> Claim {
        var claim = Claim.make(.trip)
        claim.title = "宁波项目出差"; claim.department = "软件部"; claim.tripPurpose = "智能制造项目现场实施与调试"
        claim.setTravelerNames(["张三"])
        claim.dates = Set([7, 8, 9, 12, 13, 14, 19, 20, 21, 22, 23].map { String(format: "2026-10-%02d", $0) })
        let days = [7, 9, 12, 14, 19, 23], amounts: [Int64] = [6900, 8500, 6900, 6200, 6900, 6200]
        claim.expenses = days.enumerated().map { index, day in
            let date = String(format: "2026-10-%02d", day)
            return Expense(kind: .train, unitPrice: amounts[index], origin: index % 2 == 0 ? "杭州东" : "宁波", destination: index % 2 == 0 ? "宁波" : "杭州东",
                           departureTime: date, arrivalTime: date,
                           invoices: [Attachment(name: "张三车票\(index).pdf", storedName: "demo\(index).pdf", amount: amounts[index], number: "2631200000251784613\(index)")], claimant: "张三")
        }
        claim.expenses.append(Expense(kind: .subsidy, unitPrice: 5000, claimant: "张三"))
        claim.expenses.append(Expense(kind: .taxi, unitPrice: 10631,
                                      invoices: [Attachment(name: "打车发票.pdf", storedName: "taxi.pdf", amount: 10631)],
                                      itineraries: [Attachment(name: "行程单.pdf", storedName: "itinerary.pdf", amount: 99999)], claimant: "张三"))
        claim.expenseOrder = [.train, .subsidy, .taxi]
        claim.updatedAt = DayKey.date("2026-11-02")!
        return claim
    }

    @MainActor func testTripFormReconciliationAndRendering() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        var claim = tripFormFixture()
        let data = TripFormData(claim: claim, person: claim.personBreakdowns[0])
        expectEqual(data.fare, 41600); expectEqual(data.subsidy, 55000); expectEqual(data.otherTotal, 10631)
        expectEqual(data.total, 107231); expectEqual(data.invoiceCount, 7)
        expectEqual(data.fare + data.subsidy + data.otherTotal, data.total)
        expectEqual(data.subsidies, [1: 15000, 3: 15000, 5: 25000])
        expectEqual(ChineseMoney.uppercase(data.total), "壹仟零柒拾贰元叁角壹分")
        expectEqual(ChineseMoney.uppercase(10001), "壹佰元零壹分")
        expectEqual(ChineseMoney.uppercase(100000100), "壹佰万零壹元整")
        expectEqual(ChineseMoney.uppercase(0), "零元整")
        expectEqual(TripFormData.momentParts(nil, place: "宁波"), ["", "", "", "宁波"])
        try captureView(TripFormPaper(data: data), width: TripFormPaper.width, height: TripFormPaper.height(for: data), to: qa.appendingPathComponent("trip-form-paper.png"))
        claim.travelerNames = ["张三", "李四"]
        claim.expenses[claim.expenses.count - 1].claimant = "李四"
        var hotel = Expense(kind: .hotel, claimant: "李四"); hotel.setTotalAmount(20000); claim.expenses.append(hotel)
        let people = claim.personBreakdowns.map { TripFormData(claim: claim, person: $0) }
        expectEqual(people.reduce(0) { $0 + $1.total }, claim.total)
        expectTrue(people.allSatisfy { $0.fare + $0.subsidy + $0.otherTotal == $0.total })
        expectEqual(people[1].otherTotal, 30631)
        try captureView(TripFormPreview(claim: claim).background(Palette.canvas).tint(Palette.accent), width: 1000, height: 740, to: qa.appendingPathComponent("trip-form-preview.png")) { window, host in
            nativeClick(NSPoint(x: 114, y: host.isFlipped ? 74 : host.bounds.height - 74), in: host, window: window)
        }
        var many = tripFormFixture(); many.expenses += many.expenses.filter { $0.kind == .train }.map { row in var row = row; row.id = UUID(); return row }
        many.tripPurpose = String(repeating: "智能制造项目现场实施与调试、", count: 4); many.note = "现场对接，完成测试后返程。"
        let manyData = TripFormData(claim: many)
        expectEqual(manyData.rowCount, 12)
        try captureView(TripFormPaper(data: manyData), width: TripFormPaper.width, height: TripFormPaper.height(for: manyData), to: qa.appendingPathComponent("trip-form-long.png"))
        var empty = Claim.make(.trip); empty.expenses = []
        expectEqual(TripFormData(claim: empty).total, 0)
        expectEqual(TripFormData(claim: empty).rowCount, 7)
    }

    @MainActor func testTripFormNativeEditorAndTimeSelection() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let suite = "Reimbur-trip-ui-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = tripFormFixture(); claim.expenses.reverse(); expectTrue(store.save(claim))
        @MainActor func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        @MainActor func edit(_ field: NSTextField, value: String, host: NSView, window: NSWindow) {
            nativeClick(host.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field), in: host, window: window)
            guard let editor = window.firstResponder as? NSTextView else { fail("New field not editable"); return }
            editor.selectAll(nil); editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil); pumpNativeEvents()
        }
        try captureView(SettingsView().environmentObject(store).defaultAppStorage(defaults).textFieldStyle(.roundedBorder).background(Palette.canvas).tint(Palette.accent),
                        width: 1180, height: 1100, to: qa.appendingPathComponent("trip-default-settings.png")) { window, host in
            guard let department = fields(host).first(where: { $0.placeholderString == "填写部门" }),
                  let purpose = fields(host).first(where: { $0.placeholderString == "填写出差事由" }) else { fail("Default fields missing"); return }
            edit(department, value: "研发部", host: host, window: window)
            edit(purpose, value: "设备调试", host: host, window: window)
            expectEqual(ExpenseDefaults.saved(in: defaults).department, "研发部")
            expectEqual(ExpenseDefaults.saved(in: defaults).tripPurpose, "设备调试")
        }
        try captureView(ClaimEditor(claim: claim).overlay { WorkspacePreviewLayer() }.environmentObject(store).defaultAppStorage(defaults).background(Palette.canvas).tint(Palette.accent),
                        width: 1500, height: 1550, to: qa.appendingPathComponent("trip-editor-form-open.png")) { window, host in
            guard let department = fields(host).first(where: { $0.placeholderString == "填写部门" }),
                  let purpose = fields(host).first(where: { $0.placeholderString == "填写出差事由" }) else { fail("Basic info fields missing"); return }
            edit(department, value: "实施部", host: host, window: window)
            edit(purpose, value: "客户现场调试", host: host, window: window)
            expectEqual(store.claims.first { $0.id == claim.id }?.department, "实施部")
            expectEqual(store.claims.first { $0.id == claim.id }?.tripPurpose, "客户现场调试")
            @MainActor func cornerBrightness() -> CGFloat {
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                return bitmap.colorAt(x: 20, y: 20)!.usingColorSpace(.deviceRGB)!.redComponent
            }
            let before = cornerBrightness()
            nativeClick(NSPoint(x: 1245, y: host.isFlipped ? 892 : host.bounds.height - 892), in: host, window: window)
            expectTrue(cornerBrightness() < before - 0.2)
            let overlayBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: overlayBitmap)
            try? FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try? overlayBitmap.representation(using: .png, properties: [:])?.write(to: qa.appendingPathComponent("trip-form-overlay.png"))
            nativeClick(NSPoint(x: 10, y: host.isFlipped ? 50 : host.bounds.height - 50), in: host, window: window)
            expectTrue(cornerBrightness() > before - 0.05)
        }
        let state = TripListState(claim)
        try captureView(TripListInteractionView(state: state, store: store).defaultAppStorage(defaults).tint(Palette.accent), width: 1550, height: 570,
                        to: qa.appendingPathComponent("train-times.png")) { window, host in
            let popups: [NSPopUpButton] = { @MainActor func find(_ node: NSView) -> [NSPopUpButton] { (node as? NSPopUpButton).map { [$0] } ?? node.subviews.flatMap(find) }; return find(host) }()
            let origins = popups.filter { $0.titleOfSelectedItem == "杭州" || $0.titleOfSelectedItem == "宁波" }
                .sorted { host.convert($0.bounds, from: $0).minY < host.convert($1.bounds, from: $1).minY }
            expectEqual(origins.first?.titleOfSelectedItem, "杭州")
            guard let firstOrigin = origins.first else { fail("Train origin missing"); return }
            let y = host.convert(firstOrigin.bounds, from: firstOrigin).midY
            let widths = TripExpenseColumns.widths(for: 1510, kind: .train)
            let point = NSPoint(x: 20 + widths.prefix(2).reduce(0, +) + widths[2] / 2, y: y)
            let knownWindows = Set(NSApplication.shared.windows.map(\.windowNumber))
            nativeClick(point, in: host, window: window)
            guard let popover = NSApplication.shared.windows.first(where: { $0.isVisible && !knownWindows.contains($0.windowNumber) }), let content = popover.contentView else { fail("Time popover not opened"); return }
            let popupBitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: popupBitmap)
            try? popupBitmap.representation(using: .png, properties: [:])?.write(to: qa.appendingPathComponent("rail-time-popover.png"))
            nativeClick(NSPoint(x: 54, y: content.isFlipped ? content.bounds.height - 41 : 41), in: content, window: popover)
            let firstID = RailMoment.ordered(claim.expenses.filter { $0.kind == .train })[0].id
            expectNil(state.claim.expenses.first { $0.id == firstID }?.departureTime)
            expectNil(ClaimStore(root: store.root).claims.first { $0.id == claim.id }?.expenses.first { $0.id == firstID }?.departureTime)
            // Clearing moves the row to the end of the default chronological order.
            expectEqual(RailMoment.ordered(state.claim.expenses.filter { $0.kind == .train }).last?.id, firstID)
            let lastY = y + (host.isFlipped ? 1 : -1) * 60 * 5
            nativeClick(NSPoint(x: point.x, y: lastY), in: host, window: window)
            guard let activePopover = NSApplication.shared.windows.first(where: { $0.isVisible && $0 !== window && $0.contentView != nil }) else { fail("Blank time popover not opened"); return }
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: activePopover.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            activePopover.sendEvent(enter); pumpNativeEvents()
            expectEqual(state.claim.expenses.first { $0.id == firstID }?.departureTime, "2026-10-07")
        }
    }

    @MainActor func testTripMixedBatchImportAndRollback() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三", "李四"])
        claim.dates = ["2026-10-28", "2026-10-29"]
        claim.expenses = []
        claim.addExpense(.taxi, unitPrice: 0)
        let emptyRowID = claim.expenses[0].id
        let a = temporary.appendingPathComponent("发票A.pdf")
        let b = temporary.appendingPathComponent("发票B.pdf")
        let itinerary = temporary.appendingPathComponent("混合附件.pdf")
        let orphan = temporary.appendingPathComponent("未关联行程.pdf")
        try makeTripImportPDF(a, lines: ["电子发票（普通发票）", "发票号码：12345678901234567890", "订单号：ORDER000001", "价税合计 ¥38.00", "备注：可另附行程单"])
        try makeTripImportPDF(b, lines: ["电子发票（普通发票）", "发票号码：12345678901234567891", "订单号：ORDER000002", "价税合计 ¥62.00"])
        try makeTripImportPDF(itinerary, lines: ["高德地图 打车行程单", "订单号：ORDER000002", "发票号码：12345678901234567891", "合计金额 ¥999.00"])
        try makeTripImportPDF(orphan, lines: ["打车行程单", "订单号：ORDER999999", "合计金额 ¥500.00"])
        expectEqual(TripImportRecognition.role(text: "电子发票（普通发票）\n备注：另附行程单", filename: "行程单.pdf"), .invoice)
        expectEqual(TripImportRecognition.role(text: "高德地图 打车 行 程 单\n底部说明：电子发票另附", filename: "附件.pdf"), .itinerary)
        claim = try store.importTripFiles([itinerary, a, orphan, b], into: claim, kind: .taxi)
        expectEqual(claim.expenses.count, 3)
        expectEqual(claim.expenses[0].id, emptyRowID)
        expectEqual(claim.invoiceCount, 2)
        expectEqual(claim.invoiceTotal, 10000)
        expectEqual(claim.total, 10000)
        expectEqual(claim.expenses.first { $0.invoices.first?.number == "12345678901234567891" }?.itineraries?.count, 1)
        expectEqual(claim.expenses.filter { $0.invoices.isEmpty }.first?.total(in: claim), 0)
        expectTrue(claim.expenses.allSatisfy { $0.claimant == "张三" })
        expectEqual(claim.attachments.count, 4)
        for file in claim.attachments {
            expectTrue(file.name.hasPrefix("张三"))
            expectTrue(FileManager.default.fileExists(atPath: store.url(for: file).path))
        }
        let source = claim.expenses.first { $0.invoices.isEmpty }!
        let target = claim.expenses.first { $0.invoices.first?.number == "12345678901234567890" }!
        claim = store.moveItinerary(source.itineraries![0], in: claim, from: source.id, to: target.id)!
        expectEqual(claim.total, 10000)
        expectEqual(claim.invoiceCount, 2)
        expectEqual(claim.expenses.first { $0.id == target.id }?.itineraries?.count, 1)
        // Existing records and original attachments survive a malformed file anywhere in the selection.
        let before = ClaimStore(root: store.root).claims[0]
        let bad = temporary.appendingPathComponent("损坏.pdf")
        try Data("not pdf".utf8).write(to: bad)
        let directory = store.root.appendingPathComponent("Attachments")
        let beforeNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        expectThrowsError(try store.importTripFiles([a, bad], into: claim, kind: .taxi))
        expectEqual(ClaimStore(root: store.root).claims[0], before)
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), beforeNames)
        // Duplicate imports retain independent rows and unique filenames.
        claim = try store.importTripFiles([a, a], into: claim, kind: .taxi)
        expectEqual(claim.invoiceCount, 4)
        expectEqual(Set(claim.attachments.map(\.name)).count, claim.attachments.count)
        expectEqual(claim.total, 17600)
        // A rejected final save also removes copied files rather than resurrecting a deleted record.
        var deleted = Claim.make(.trip); deleted.expenses = []; deleted.setTravelerNames(["李四"])
        expectTrue(store.save(deleted)); expectTrue(store.delete(deleted))
        let savedNames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        expectThrowsError(try store.importTripFiles([a, b], into: deleted, kind: .taxi))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), savedNames)
        expectFalse(store.claims.contains { $0.id == deleted.id })
        // Trains remain one row per file, even for multi-page PDFs, with route and amount recognition.
        var rail = Claim.make(.trip); rail.expenses = []; rail.setTravelerNames(["张三"])
        let ticket = temporary.appendingPathComponent("车票.pdf")
        try makePDF(at: ticket, pages: 2, number: "22345678901234567890", amount: "553.00")
        rail = try store.importTripFiles([ticket, ticket], into: rail, kind: .train)
        expectEqual(rail.expenses.count, 2)
        expectEqual(rail.invoiceCount, 2)
        expectEqual(rail.total, 110600)
        expectTrue(rail.expenses.allSatisfy { $0.origin == "上海" && $0.destination == "杭州" && $0.invoices[0].pageCount == 2 })
        // A scanned itinerary uses local OCR, while image itineraries remain outside invoice totals.
        let pdf = PDFDocument(url: itinerary)!
        let image = pdf.page(at: 0)!.thumbnail(of: NSSize(width: 1190, height: 1684), for: .mediaBox)
        let scan = temporary.appendingPathComponent("扫描附件.pdf")
        let scanned = PDFDocument(); scanned.insert(PDFPage(image: image)!, at: 0)
        expectTrue(scanned.write(to: scan))
        expectEqual(try TripImportRecognition.inspect(scan, kind: .taxi).role, .itinerary)
        let photo = temporary.appendingPathComponent("行程截图.png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: photo)
        let count = claim.invoiceCount, total = claim.total
        claim = try store.importTripFiles([scan, photo], into: claim, kind: .taxi)
        expectEqual(claim.invoiceCount, count)
        expectEqual(claim.total, total)
        expectEqual(ClaimStore(root: store.root).claims.first { $0.id == claim.id }?.expenses, claim.expenses)
    }

    @MainActor func testTripListNativeEditingAndScreenshots() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = sampleClaim()
        claim.expenses = [Expense(kind: .train, unitPrice: 55300, origin: "上海虹桥", destination: "杭州东", claimant: "张三"),
                          Expense(kind: .train, unitPrice: 28000, origin: "杭州东", destination: "上海虹桥", claimant: "李四")]
        claim.expenses[0].note = "保留历史说明"
        claim.expenses[0].invoices = [Attachment(name: "车票A.pdf", storedName: "a.pdf", amount: 30000, number: "12345678901234567890"),
                                      Attachment(name: "车票B.pdf", storedName: "b.pdf", amount: 25300, number: "12345678901234567891")]
        claim.expenses[1].invoices = [Attachment(name: "车票C.pdf", storedName: "c.pdf", amount: 28000, number: "12345678901234567892")]
        expectTrue(store.save(claim))
        for invoice in claim.expenses.flatMap(\.invoices) {
            try makePDF(at: store.url(for: invoice), pages: 1, number: invoice.number ?? "", amount: Money.input(invoice.amount))
        }
        let state = TripListState(claim)
        let view = TripListInteractionView(state: state, store: store).tint(Palette.accent)
        try captureView(view, width: 1450, height: 310, to: qa.appendingPathComponent("trip-list-edited.png")) { window, host in
            @MainActor func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
            @MainActor func edit(_ field: NSTextField, _ value: String) {
                nativeClick(host.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field), in: host, window: window)
                guard let editor = window.firstResponder as? NSTextView else { fail("Trip cell not editable"); return }
                editor.selectAll(nil); editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
                window.makeFirstResponder(nil); pumpNativeEvents()
            }
            @MainActor func popups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups) }
            expectFalse(fields(host).contains { $0.placeholderString == "选填说明" })
            expectEqual(fields(host).filter { $0.placeholderString == "发票号码" }.count, 3)
            guard let invoiceNumber = fields(host).first(where: { $0.stringValue == "12345678901234567890" }),
                  let origin = popups(host).first(where: { $0.titleOfSelectedItem == "上海" }) else { fail("Trip list cells missing"); return }
            edit(invoiceNumber, "22345678901234567890")
            edit(fields(host).first(where: { $0.stringValue == "300.00" })!, "310.00")
            expectEqual(state.claim.total, 84300)
            expectEqual(state.claim.invoiceTotal, 84300)
            expectFalse(fields(host).contains { $0.stringValue == "553.00" })
            let freshNumber = fields(host).first { $0.stringValue == "22345678901234567890" }!
            let numberRect = host.convert(freshNumber.bounds, from: freshNumber)
            let fileWidth = TripExpenseColumns.widths(for: 1410, kind: .train)[7]
            nativeClick(nativeFilePreviewPoint(state.claim.expenses[0].invoices[0].name, columnStart: numberRect.maxX + 10, columnWidth: fileWidth, y: numberRect.midY), in: host, window: window)
            expectEqual(store.preview?.attachment.id, state.claim.expenses[0].invoices[0].id)
            origin.selectItem(withTitle: "手动输入…")
            origin.sendAction(origin.action!, to: origin.target); pumpNativeEvents()
            let customField = NSApplication.shared.windows.compactMap(\.contentView).flatMap(fields).first { $0.placeholderString == "输入地点" }
            if let field = customField, let editor = field.currentEditor() as? NSTextView {
                editor.selectAll(nil); editor.insertText("上海南", replacementRange: NSRange(location: NSNotFound, length: 0))
                let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: field.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                field.window!.sendEvent(enter); pumpNativeEvents()
            } else { fail("Custom station field not focused") }
            expectEqual(state.claim.expenses[0].note, "保留历史说明")
            expectEqual(state.claim.expenses[0].invoices[0].number, "22345678901234567890")
            expectEqual(state.claim.expenses[0].total(in: state.claim), 56300)
            expectEqual(state.claim.expenses[0].origin, "上海南")
            expectEqual(state.claim.total, 84300)
            expectEqual(store.claims.first { $0.id == claim.id }?.expenses, state.claim.expenses)
        }
        var demo = sampleClaim()
        demo.title = "杭州项目出差"; demo.status = .pending
        for i in 0..<4 {
            let amount = Int64(21000 + i * 2500)
            let invoice = Attachment(name: "张三车票\(i).pdf", storedName: "demo\(i).pdf", amount: amount, number: "2631200000251784613\(i)")
            let origin = i % 2 == 0 ? "杭州东" : "上海虹桥"
            let destination = i % 2 == 0 ? "上海虹桥" : "杭州东"
            demo.expenses.append(Expense(kind: .train, unitPrice: amount, origin: origin, destination: destination,
                                         note: "项目往返交通", invoices: [invoice], claimant: i % 2 == 0 ? "张三" : "李四"))
        }
        demo.expenseOrder = [.train, .subsidy, .hotel]
        expectTrue(store.save(demo))
        try captureView(ClaimEditor(claim: demo).environmentObject(store).background(Palette.canvas).tint(Palette.accent), width: 1500, height: 1700,
                        to: qa.appendingPathComponent("trip-expenses.png"))
        var meal = Claim.make(.meal); meal.title = "十月餐补报销"; meal.status = .archived
        meal.setTravelerNames(["张三"]); meal.dates = ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29"]
        meal.expenses[0].unitPrice = 3000
        for i in 1...3 {
            let pdf = temporary.appendingPathComponent("餐补发票\(i).pdf")
            try makePDF(at: pdf, pages: 1, number: "2631200000251784613\(i)", amount: "38.00")
            meal = try store.importFiles([pdf], into: meal, expenseID: meal.expenses[0].id)
            meal.invoiceLedgerEntries?[i - 1].detail = "工作日餐费"
        }
        expectTrue(store.save(meal))
        try captureView(ClaimEditor(claim: meal).environmentObject(store).background(Palette.canvas).tint(Palette.accent), width: 1500, height: 1120, to: qa.appendingPathComponent("meal-ledger.png"))
    }

    @MainActor func testTaxiAttachmentDisclosure() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip); claim.expenses = []; claim.setTravelerNames(["张三"])
        let invoice = temporary.appendingPathComponent("打车发票.pdf")
        let itinerary = temporary.appendingPathComponent("关联行程单.pdf")
        try makeTripImportPDF(invoice, lines: ["电子发票（普通发票）", "发票号码：12345678901234567890", "订单号：ORDER000001", "价税合计 ¥38.00"])
        try makeTripImportPDF(itinerary, lines: ["高德地图 打车行程单", "订单号：ORDER000001", "发票号码：12345678901234567890"])
        claim = try store.importTripFiles([invoice, itinerary], into: claim, kind: .taxi)
        let state = TripListState(claim)
        let view = TripAttachmentsInteractionView(state: state, store: store).tint(Palette.accent)
        try captureView(view, width: 1250, height: 330, to: qa.appendingPathComponent("taxi-columns.png")) { window, host in
            @MainActor func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
            guard let number = fields(host).first(where: { $0.placeholderString == "发票号码" }) else { fail("Taxi invoice number missing"); return }
            let rect = host.convert(number.bounds, from: number)
            let widths = TripExpenseColumns.widths(for: 1170, kind: .taxi)
            // The itinerary is a first-class cell beside the invoice, with its own preview.
            nativeClick(nativeFilePreviewPoint(state.claim.expenses[0].itineraries![0].name, columnStart: rect.maxX + 10 + widths[3], columnWidth: widths[4], y: rect.midY), in: host, window: window)
            expectEqual(store.preview?.attachment.id, state.claim.expenses[0].itineraries?.first?.id)
            expectEqual(state.claim.invoiceCount, 1)
            expectEqual(state.claim.total, 3800)
            expectEqual(state.claim.expenses[0].itineraries?.count, 1)
        }
    }

    @MainActor func testInlineLedgerFilesAndSubsidyColumns() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        @MainActor func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        @MainActor func edit(_ field: NSTextField, _ value: String, host: NSView, window: NSWindow) {
            nativeClick(host.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field), in: host, window: window)
            guard let editor = window.firstResponder as? NSTextView else { fail("Inline cell not editable"); return }
            editor.selectAll(nil); editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil); pumpNativeEvents()
        }
        for kind in [ClaimKind.meal, .allowance] {
            var claim = Claim.make(kind); claim.setTravelerNames(["张三"])
            claim.dates = ["2026-10-28", "2026-10-29"]
            claim.expenses[0].unitPrice = 3000
            if kind == .allowance { claim.allowanceAmount = 68000; claim.reimbursementPurpose = "电脑配件" }
            let pdf = temporary.appendingPathComponent("测试发票.pdf")
            try makePDF(at: pdf, pages: 1, number: "26337000000777118119", amount: "241.00")
            claim = try store.importFiles([pdf], into: claim, expenseID: claim.expenses[0].id)
            let state = TripListState(claim)
            let originalTotal = claim.total
            let view = InlineLedgerInteractionView(state: state, store: store).tint(Palette.accent)
            try captureView(view, width: 1300, height: 330, to: qa.appendingPathComponent("inline-\(kind.rawValue).png")) { window, host in
                guard let number = fields(host).first(where: { $0.placeholderString == "发票号码" }),
                      fields(host).contains(where: { $0.stringValue == "241.00" }) else {
                    fail("Inline ledger invoice fields missing"); return
                }
                expectEqual(fields(host).filter { $0.stringValue == "241.00" }.count, 2)
                let rect = host.convert(number.bounds, from: number)
                let fileWidth = InvoiceLedgerColumns.widths(for: 1220)[4]
                nativeClick(nativeFilePreviewPoint(state.claim.invoiceLedgerRows[0].invoice!.name, columnStart: rect.maxX + 10, columnWidth: fileWidth, y: rect.midY), in: host, window: window)
                expectEqual(store.preview?.attachment.id, state.claim.invoiceLedgerRows[0].invoice?.id)
                if let preview = store.preview { expectTrue(PDFDocument(url: preview.url) != nil) }
                else { fail("Preview request missing") }
                let currentAmount = fields(host).filter { $0.stringValue == "241.00" }.min { host.convert($0.bounds, from: $0).midX < host.convert($1.bounds, from: $1).midX }!
                edit(currentAmount, "250.00", host: host, window: window)
                expectEqual(state.claim.invoiceTotal, 25000)
                expectEqual(state.claim.total, originalTotal)
                expectEqual(state.claim.ledgerReimbursementTotal, 24100)
                nativeClick(NSPoint(x: rect.maxX + 10 + fileWidth / 2 + 15, y: rect.midY), in: host, window: window)
                guard let name = fields(host).first(where: { $0.placeholderString == "附件名称" }) else { fail("Inline filename editor missing"); return }
                edit(name, "核对发票", host: host, window: window)
                expectEqual(state.claim.invoiceLedgerRows[0].invoice?.name, "核对发票.pdf")
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: qa.appendingPathComponent("inline-\(kind.rawValue)-with-invoice.png"))
                // The row's delete control removes its invoice and linked ledger entry immediately.
                let deleteX: CGFloat = 1300 - 40 - 26
                nativeClick(NSPoint(x: deleteX, y: rect.midY), in: host, window: window)
                expectEqual(state.claim.invoiceCount, 0)
                expectEqual(state.claim.invoiceLedgerRows.count, 0)
                expectEqual(state.claim.total, originalTotal)
                expectEqual(store.claims.first { $0.id == state.claim.id }?.invoiceCount, 0)
            }
        }
        var trip = Claim.make(.trip); trip.setTravelerNames(["张三", "李四"])
        trip.dates = ["2026-10-27", "2026-10-28", "2026-10-29"]
        trip.expenses = [Expense(kind: .subsidy, unitPrice: 10000, dates: ["2026-10-28", "2026-10-29"], claimant: "张三"),
                         Expense(kind: .subsidy, unitPrice: 10000, claimant: "李四")]
        let state = TripListState(trip)
        try captureView(SubsidyListInteractionView(state: state).tint(Palette.accent), width: 1050, height: 260, to: qa.appendingPathComponent("subsidy-columns.png")) { window, host in
            expectEqual(fields(host).filter { $0.placeholderString == "发票号码" }.count, 0)
            let prices = fields(host).filter { $0.stringValue == "100.00" }
            expectEqual(prices.count, 2)
            if let price = prices.first { edit(price, "120.00", host: host, window: window) }
            expectEqual(state.claim.total, 54000)
        }
    }

    @MainActor func testHoverSortingCenteredCellsAndOverlayScrollbar() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let suite = "Reimbur-hover-table-\(UUID())", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalCursor = NSEvent.mouseLocation
        defer { CGWarpMouseCursorPosition(CGPoint(x: originalCursor.x, y: NSScreen.screens[0].frame.maxY - originalCursor.y)) }
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        @MainActor func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        @MainActor func popups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups) }
        @MainActor func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        @MainActor func move(_ point: NSPoint, _ host: NSView, _ window: NSWindow) {
            window.acceptsMouseMovedEvents = true
            let screenPoint = window.convertPoint(toScreen: host.convert(point, to: nil))
            let globalPoint = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.maxY - screenPoint.y)
            CGWarpMouseCursorPosition(globalPoint)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: globalPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: host.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: 0, pressure: 0)!
            NSApplication.shared.postEvent(event, atStart: false); pumpNativeEvents(0.3)
        }
        @MainActor func snapshot(_ host: NSView, _ name: String) {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: qa.appendingPathComponent(name))
        }
        var trip = Claim.make(.trip); trip.setTravelerNames(["张三", "李四"])
        trip.dates = ["2026-10-28", "2026-10-29"]
        trip.expenses = [Expense(kind: .subsidy, unitPrice: 8000, note: "原始第一笔", claimant: "张三"),
                         Expense(kind: .subsidy, unitPrice: 5000, note: "原始第二笔", claimant: "李四"),
                         Expense(kind: .subsidy, unitPrice: 10000, note: "原始第三笔", claimant: "张三")]
        expectTrue(store.save(trip))
        let originalIDs = trip.expenses.map(\.id), state = TripListState(trip)
        let view = AdjustableTripInteractionView(state: state, store: store, kind: .subsidy).tint(Palette.accent).defaultAppStorage(defaults)
        try captureView(view, width: 1050, height: 350, to: qa.appendingPathComponent("subsidy-default.png")) { window, host in
            let scroll = scrolls(host)[0]
            expectTrue(abs(scroll.frame.height - 222) < 1)
            expectTrue(abs((scroll.documentView?.frame.width ?? 0) - scroll.contentView.bounds.width) < 1)
            expectTrue(fields(host).filter(\.isEditable).allSatisfy { $0.alignment == .center })
            expectTrue(popups(host).allSatisfy { $0.alignment == .center })
            let price = fields(host).first { $0.stringValue == "80.00" }!
            let rect = host.convert(price.bounds, from: price), sign: CGFloat = host.isFlipped ? 1 : -1
            let widths = TripExpenseColumns.widths(for: 1010, kind: .subsidy)
            let header = NSPoint(x: 20 + widths.prefix(3).reduce(0, +) + widths[3] / 2, y: rect.midY - sign * 51)
            move(NSPoint(x: 10, y: 10), host, window); snapshot(host, "header-hidden.png")
            move(header, host, window); snapshot(host, "header-hover-default.png")
            expectTrue((try? Data(contentsOf: qa.appendingPathComponent("header-hidden.png"))) != (try? Data(contentsOf: qa.appendingPathComponent("header-hover-default.png"))))
            @MainActor func headerSlice(_ file: String, column: Int) -> Data? {
                guard let data = try? Data(contentsOf: qa.appendingPathComponent(file)), let image = NSBitmapImageRep(data: data)?.cgImage else { return nil }
                let scale = CGFloat(image.width) / host.bounds.width
                let top = host.isFlipped ? header.y - 21 : host.bounds.height - header.y - 21
                let area = CGRect(x: (20 + widths.prefix(column).reduce(0, +)) * scale, y: top * scale, width: widths[column] * scale, height: 42 * scale)
                guard let slice = image.cropping(to: area) else { return nil }
                return NSBitmapImageRep(cgImage: slice).representation(using: .png, properties: [:])
            }
            for index in 0..<6 where index != 3 {
                expectEqual(headerSlice("header-hidden.png", column: index), headerSlice("header-hover-default.png", column: index))
            }
            nativeClick(header, in: host, window: window)
            expectEqual(state.claim.expenses.map(\.unitPrice), [5000, 8000, 10000]); snapshot(host, "header-ascending.png")
            expectTrue(headerSlice("header-hover-default.png", column: 3) != headerSlice("header-ascending.png", column: 3))
            nativeClick(header, in: host, window: window)
            expectEqual(state.claim.expenses.map(\.unitPrice), [10000, 8000, 5000]); snapshot(host, "header-descending.png")
            nativeClick(header, in: host, window: window)
            expectEqual(state.claim.expenses.map(\.id), originalIDs)
            move(NSPoint(x: 10, y: 10), host, window)
        }
        // Restoring the baseline still works after reopening, with added/deleted rows.
        var reloaded = ClaimStore(root: store.root).claims.first { $0.id == trip.id }!
        reloaded.sortExpenses(.subsidy, column: "price", ascending: true)
        let newExpense = Expense(kind: .subsidy, unitPrice: 6000, claimant: "张三")
        reloaded.expenses.append(newExpense); reloaded.expenses.removeAll { $0.id == originalIDs[1] }
        expectTrue(store.save(reloaded))
        reloaded = ClaimStore(root: store.root).claims.first { $0.id == trip.id }!
        reloaded.sortExpenses(.subsidy, column: "price", ascending: nil)
        expectEqual(reloaded.expenses.map(\.id), [originalIDs[0], originalIDs[2], newExpense.id])
        for kind in [ClaimKind.meal, .allowance] {
            var claim = Claim.make(kind); claim.setTravelerNames(["张三"])
            if kind == .allowance { claim.allowanceAmount = 50000; claim.reimbursementPurpose = "办公配件" }
            let expenseID = claim.expenses[0].id
            claim.expenses[0].invoices = [Attachment(name: "张三发票A.pdf", storedName: "a.pdf", amount: 3800, number: "12345678901234567890"),
                                          Attachment(name: "张三发票B.pdf", storedName: "b.pdf", amount: 2400, number: "12345678901234567891")]
            claim.invoiceLedgerEntries = claim.expenses[0].invoices.map {
                InvoiceLedgerEntry(id: $0.id, expenseID: expenseID, invoiceID: $0.id, date: "2026-10-29", claimant: "张三", reimbursementAmount: $0.amount, detail: "工作餐")
            }
            expectTrue(store.save(claim))
            let ledgerState = TripListState(claim), baseline = claim.invoiceLedgerRows.map(\.id)
            let ledger = InlineLedgerInteractionView(state: ledgerState, store: store).tint(Palette.accent).defaultAppStorage(defaults)
            try captureView(ledger, width: 1550, height: 470, to: qa.appendingPathComponent("ledger-\(kind.rawValue).png")) { window, host in
                expectTrue(fields(host).filter(\.isEditable).allSatisfy { $0.alignment == .center })
                let amount = fields(host).first { $0.stringValue == "38.00" }!
                let rect = host.convert(amount.bounds, from: amount), sign: CGFloat = host.isFlipped ? 1 : -1
                let widths = InvoiceLedgerColumns.widths(for: 1470)
                let header = NSPoint(x: 40 + widths.prefix(5).reduce(0, +) + widths[5] / 2, y: rect.midY - sign * 51)
                nativeClick(header, in: host, window: window)
                expectEqual(ledgerState.claim.invoiceLedgerRows.map { $0.invoice?.amount }, [2400, 3800])
                nativeClick(header, in: host, window: window)
                expectEqual(ledgerState.claim.invoiceLedgerRows.map { $0.invoice?.amount }, [3800, 2400])
                nativeClick(header, in: host, window: window)
                expectEqual(ledgerState.claim.invoiceLedgerRows.map(\.id), baseline)
                var saved = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
                saved.sortLedgerRows(column: "amount", ascending: true); expectTrue(store.save(saved))
                saved = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
                saved.sortLedgerRows(column: "amount", ascending: nil)
                expectEqual(saved.invoiceLedgerRows.map(\.id), baseline)
                expectEqual(saved.expenses[0].invoices.map(\.id), claim.expenses[0].invoices.map(\.id))
                move(NSPoint(x: 10, y: 10), host, window)
            }
            if kind == .meal {
                try captureView(ledger, width: 950, height: 470, to: qa.appendingPathComponent("scrollbar-hidden.png")) { window, host in
                    let scroll = scrolls(host)[0], rect = host.convert(scroll.bounds, from: scroll)
                    expectTrue((scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width)
                    expectTrue(abs(scroll.frame.height - 162) < 1)
                    let point = NSPoint(x: rect.midX, y: host.isFlipped ? rect.maxY + 6 : rect.minY - 6)
                    move(NSPoint(x: 10, y: 10), host, window); snapshot(host, "scrollbar-before-hover.png")
                    move(point, host, window); snapshot(host, "scrollbar-hover.png")
                    expectTrue((try? Data(contentsOf: qa.appendingPathComponent("scrollbar-before-hover.png"))) != (try? Data(contentsOf: qa.appendingPathComponent("scrollbar-hover.png"))))
                    move(NSPoint(x: 10, y: 10), host, window); snapshot(host, "scrollbar-after-leave.png")
                    expectEqual(try? Data(contentsOf: qa.appendingPathComponent("scrollbar-before-hover.png")), try? Data(contentsOf: qa.appendingPathComponent("scrollbar-after-leave.png")))
                    move(point, host, window)
                    nativeDrag(from: point, to: NSPoint(x: point.x + 80, y: point.y), in: host, window: window)
                    expectTrue(scroll.contentView.bounds.minX > 50)
                    move(NSPoint(x: 10, y: 10), host, window)
                }
            }
        }
        var train = trip; train.expenses = [Expense(kind: .train, unitPrice: 24100, origin: "上海虹桥", destination: "杭州东", invoices: [Attachment(name: "张三火车电子发票.pdf", storedName: "demo.pdf", amount: 24100, number: "26337000000777118119")], claimant: "张三")]
        expectTrue(store.save(train))
        try makePDF(at: store.url(for: train.expenses[0].invoices[0]), pages: 1, number: "26337000000777118119", amount: "241.00")
        let trainState = TripListState(train)
        try captureView(AdjustableTripInteractionView(state: trainState, store: store, kind: .train).tint(Palette.accent).defaultAppStorage(defaults),
                        width: 1350, height: 250, to: qa.appendingPathComponent("train-centered.png")) { window, host in
            let widths = TripExpenseColumns.widths(for: 1310, kind: .train)
            let amount = fields(host).first { $0.stringValue == "241.00" }!
            let rect = host.convert(amount.bounds, from: amount)
            nativeClick(nativeFilePreviewPoint(trainState.claim.expenses[0].invoices[0].name, columnStart: 20 + widths.prefix(5).reduce(0, +), columnWidth: widths[5], y: rect.midY), in: host, window: window)
            expectEqual(store.preview?.attachment.id, trainState.claim.expenses[0].invoices[0].id)
        }
        var taxi = train
        taxi.expenses[0].kind = .taxi
        taxi.expenses[0].itineraries = [Attachment(name: "张三打车行程单.pdf", storedName: "itinerary.pdf", amount: 0)]
        try captureView(AdjustableTripInteractionView(state: TripListState(taxi), store: store, kind: .taxi).tint(Palette.accent).defaultAppStorage(defaults),
                        width: 1350, height: 250, to: qa.appendingPathComponent("taxi-centered.png"))
    }

    @MainActor func testCenteredTablesAdjacentResizeAndSorting() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let suite = "Reimbur-table-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip); claim.setTravelerNames(["孙毅强", "张三"])
        claim.dates = ["2026-10-28", "2026-10-29"]
        claim.expenses = [Expense(kind: .subsidy, unitPrice: 8000, note: "待编辑备注", claimant: "孙毅强"), Expense(kind: .subsidy, unitPrice: 5000, note: "第二笔", claimant: "张三")]
        expectTrue(store.save(claim))
        let firstID = claim.expenses[0].id
        let state = TripListState(claim)
        @MainActor func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        @MainActor func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        let columns = TripExpenseColumns.columns(for: .subsidy)
        let widths = TripExpenseColumns.widths(for: 1010, kind: .subsidy)
        let direct = ReimbursementColumnSizing.resize(widths, columns: columns, left: 4, delta: 40)
        expectEqual(direct[4], widths[4] + 40); expectEqual(direct[5], widths[5] - 40)
        for index in [0, 1, 2, 3, 6] { expectEqual(direct[index], widths[index]) }
        expectEqual(direct.reduce(0, +), widths.reduce(0, +))
        expectEqual(ReimbursementColumnSizing.resize(widths, columns: columns, left: 5, delta: 500), widths)
        let bounded = ReimbursementColumnSizing.resize(widths, columns: columns, left: 4, delta: 500, maximumDelta: 12)
        expectEqual(bounded[4], widths[4] + 12)
        let view = AdjustableTripInteractionView(state: state, store: store, kind: .subsidy).tint(Palette.accent).defaultAppStorage(defaults)
        try captureView(view, width: 1050, height: 300, to: qa.appendingPathComponent("table-subsidy-resized.png")) { window, host in
            guard let price = fields(host).first(where: { $0.stringValue == "80.00" }) else { fail("Subsidy price missing"); return }
            let row = host.convert(price.bounds, from: price), sign: CGFloat = host.isFlipped ? 1 : -1
            let headerY = row.midY - sign * 51
            let dividerX = 20 + widths.prefix(5).reduce(0, +)
            nativeDrag(from: NSPoint(x: dividerX, y: headerY), to: NSPoint(x: dividerX + 40, y: headerY), in: host, window: window)
            let stored = defaults.data(forKey: "reimbursement.columns.v2.trip.出差补助").flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) }
            expectTrue(stored != nil)
            for index in columns.indices { expectTrue(abs((stored?[columns[index].id] ?? 0) - Double(direct[index])) < 3) }
            nativeDrag(from: NSPoint(x: 43, y: row.midY), to: NSPoint(x: 43, y: row.midY + sign * 65), in: host, window: window)
            expectEqual(state.claim.expenses.first?.id, firstID)
            // Numeric header sorting toggles, and order persists through SQLite.
            let priceX = 20 + direct.prefix(3).reduce(0, +) + direct[3] / 2
            nativeClick(NSPoint(x: priceX, y: headerY), in: host, window: window)
            expectEqual(state.claim.expenses.map(\.unitPrice), [5000, 8000])
            nativeClick(NSPoint(x: priceX, y: headerY), in: host, window: window)
            expectEqual(state.claim.expenses.map(\.unitPrice), [8000, 5000])
            if let note = fields(host).first(where: { $0.stringValue == "待编辑备注" }) {
                nativeClick(host.convert(NSPoint(x: note.bounds.midX, y: note.bounds.midY), from: note), in: host, window: window)
                if let editor = window.firstResponder as? NSTextView {
                    editor.selectAll(nil); editor.insertText("补助备注已编辑", replacementRange: NSRange(location: NSNotFound, length: 0))
                    window.makeFirstResponder(nil); pumpNativeEvents()
                } else { fail("Note not editable") }
            } else { fail("Subsidy note missing") }
            expectEqual(state.claim.expenses.first?.note, "补助备注已编辑")
            expectEqual(ClaimStore(root: store.root).claims.first { $0.id == claim.id }?.expenses, state.claim.expenses)
        }
        try captureView(view, width: 760, height: 300, to: qa.appendingPathComponent("table-subsidy-narrow.png"))
        for kind in [ExpenseKind.train, .flight, .taxi, .hotel] {
            var fixture = Claim.make(.trip); fixture.expenses = []; fixture.setTravelerNames(["孙毅强"])
            fixture.dates = ["2026-10-28", "2026-10-29"]
            fixture.addExpense(kind, unitPrice: 0)
            fixture.expenses[0].invoices = [Attachment(name: "孙毅强26337000000777118119电子发票.pdf", storedName: "demo.pdf", amount: 24100, number: "26337000000777118119")]
            if kind == .taxi { fixture.expenses[0].itineraries = [Attachment(name: "孙毅强26337000000777118119行程单.pdf", storedName: "trip.pdf", amount: 0)] }
            fixture.expenses[0].origin = "上海虹桥"; fixture.expenses[0].destination = "杭州东"
            let fixtureState = TripListState(fixture)
            try captureView(AdjustableTripInteractionView(state: fixtureState, store: store, kind: kind).tint(Palette.accent).defaultAppStorage(defaults),
                            width: 1350, height: 240, to: qa.appendingPathComponent("table-\(kind.rawValue).png"))
        }
        for kind in [ClaimKind.meal, .allowance] {
            var fixture = Claim.make(kind); fixture.setTravelerNames(["孙毅强"]); fixture.dates = ["2026-10-28", "2026-10-29"]
            fixture.expenses[0].unitPrice = 3000
            if kind == .allowance { fixture.allowanceAmount = 80000; fixture.reimbursementPurpose = "办公电脑配件报销" }
            let invoice = temporary.appendingPathComponent("清单发票.pdf")
            try makePDF(at: invoice, pages: 1, number: "26337000000777118119", amount: "241.00")
            fixture = try store.importFiles([invoice, invoice], into: fixture, expenseID: fixture.expenses[0].id)
            fixture.expenses[0].invoices[1].amount = 10000
            fixture.invoiceLedgerEntries?[0].detail = "原始发票与金额核对"
            let total = fixture.total
            let fixtureState = TripListState(fixture)
            let ledger = InlineLedgerInteractionView(state: fixtureState, store: store).tint(Palette.accent).defaultAppStorage(defaults)
            try captureView(ledger, width: 1550, height: 480, to: qa.appendingPathComponent("table-\(kind.rawValue).png")) { window, host in
                guard let amount = fields(host).first(where: { $0.stringValue == "241.00" }) else { fail("Ledger amount missing"); return }
                let rect = host.convert(amount.bounds, from: amount), sign: CGFloat = host.isFlipped ? 1 : -1
                nativeClick(NSPoint(x: rect.midX, y: rect.midY - sign * 51), in: host, window: window)
                expectEqual(fixtureState.claim.invoiceLedgerRows.map { $0.invoice?.amount }, [10000, 24100])
                nativeClick(NSPoint(x: rect.midX, y: rect.midY - sign * 51), in: host, window: window)
                expectEqual(fixtureState.claim.invoiceLedgerRows.map { $0.invoice?.amount }, [24100, 10000])
                expectEqual(fixtureState.claim.total, total)
                expectEqual(ClaimStore(root: store.root).claims.first { $0.id == fixture.id }?.invoiceLedgerRows.map(\.id), fixtureState.claim.invoiceLedgerRows.map(\.id))
            }
            try captureView(ledger, width: 950, height: 480, to: qa.appendingPathComponent("table-\(kind.rawValue)-narrow.png")) { window, host in
                guard let scroll = scrolls(host).first(where: { ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 50 }),
                      let number = fields(host).first(where: { $0.placeholderString == "发票号码" }) else { fail("Narrow table must scroll horizontally"); return }
                expectFalse(scroll.hasHorizontalScroller)
                let before = host.convert(number.bounds, from: number)
                scroll.contentView.scroll(to: NSPoint(x: 350, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
                pumpNativeEvents()
                guard let fresh = fields(host).first(where: { $0.placeholderString == "发票号码" }) else { fail("Scrolled table missing"); return }
                let after = host.convert(fresh.bounds, from: fresh)
                expectTrue(after.midX < before.midX - 200)
                let scrollRect = host.convert(scroll.bounds, from: scroll)
                let thumbY = host.isFlipped ? scrollRect.maxY + 4 : scrollRect.minY - 4
                nativeDrag(from: NSPoint(x: scrollRect.midX, y: thumbY), to: NSPoint(x: scrollRect.minX + 4, y: thumbY), in: host, window: window)
                expectTrue(scroll.contentView.bounds.minX < 5)
                let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -150, wheel3: 0)!
                let event = NSEvent(cgEvent: wheel)!
                scroll.scrollWheel(with: event); pumpNativeEvents()
                expectTrue(scroll.contentView.bounds.minX > 50)
                nativeClick(NSPoint(x: 950 - 40 - 108 + 24, y: after.midY), in: host, window: window)
                expectEqual(fixtureState.claim.invoiceCount, 3)
                nativeClick(NSPoint(x: 950 - 40 - 24, y: after.midY), in: host, window: window)
                expectEqual(fixtureState.claim.invoiceCount, 2)
                expectEqual(fixtureState.claim.total, total)
            }
        }
        // The public rename leaves legacy SQLite/JSON enum values intact.
        expectEqual(ClaimKind(rawValue: "补助"), .allowance)
        expectEqual(ClaimKind.allowance.displayName, "补贴")
        expectTrue(Claim.make(.allowance).title.hasPrefix("补贴报销"))
        expectEqual(ExpenseKind.subsidy.displayName, "出差补助")
        var sorted = claim
        sorted.expenses.append(Expense(kind: .train, unitPrice: 100, origin: "Z", claimant: "张三"))
        sorted.expenses.append(Expense(kind: .train, unitPrice: 200, origin: "A", claimant: "孙毅强"))
        let preserved = Array(sorted.expenses.prefix(2))
        sorted.sortExpenses(.train, column: "origin", ascending: true)
        expectEqual(sorted.expenses.filter { $0.kind == .train }.map(\.origin), ["A", "Z"])
        expectEqual(Array(sorted.expenses.prefix(2)), preserved)
    }

    @MainActor func testTableCopyReplacementAndItineraryCapacity() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        let invoice = temporary.appendingPathComponent("打车发票.pdf"), itinerary = temporary.appendingPathComponent("行程单.pdf")
        try makeTripImportPDF(invoice, lines: ["电子发票（普通发票）", "发票号码：12345678901234567890", "价税合计 ¥38.00"])
        try makeTripImportPDF(itinerary, lines: ["打车行程单", "发票号码：12345678901234567890"])
        var claim = Claim.make(.trip); claim.expenses = []; claim.setTravelerNames(["张三"])
        claim = try store.importTripFiles([invoice, itinerary], into: claim, kind: .taxi)
        let original = claim.expenses[0]
        claim = try store.duplicateExpense(original.id, in: claim)
        expectEqual(claim.invoiceCount, 2); expectEqual(claim.total, 7600)
        let copy = claim.expenses[1]
        expectTrue(original.id != copy.id)
        for (a, b) in zip(original.attachments, copy.attachments) {
            expectTrue(a.id != b.id); expectTrue(a.storedName != b.storedName)
            expectEqual(try Data(contentsOf: store.url(for: a)), try Data(contentsOf: store.url(for: b)))
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Attachments").path).sorted()
        expectThrowsError(try store.importFiles([itinerary], into: claim, expenseID: original.id, role: .itinerary))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Attachments").path).sorted(), before)
        expectTrue(store.moveItinerary(copy.itineraries![0], in: claim, from: copy.id, to: original.id) == nil)
        claim = try store.importTripFiles([itinerary], into: claim, kind: .taxi)
        expectEqual(claim.expenses.count, 3)
        expectEqual(claim.expenses[2].invoices.count, 0)
        expectEqual(claim.expenses[2].itineraries?.count, 1)
        expectEqual(claim.invoiceCount, 2)
        claim.moveExpense(copy.id, within: .taxi, to: 0)
        expectEqual(claim.expenses[0].id, copy.id)
        expectTrue(store.save(claim))
        expectEqual(ClaimStore(root: store.root).claims.first { $0.id == claim.id }?.expenses, claim.expenses)
        // A copy has independent files; removing it cannot break the original invoice.
        claim = store.removeAttachment(copy.invoices[0], from: claim, expenseID: copy.id)!
        expectTrue(FileManager.default.fileExists(atPath: store.url(for: original.invoices[0]).path))
        for kind in [ClaimKind.meal, .allowance] {
            var ledger = Claim.make(kind); ledger.setTravelerNames(["张三"]); ledger.dates = ["2026-10-28", "2026-10-29"]
            ledger.expenses[0].unitPrice = 3000
            if kind == .allowance { ledger.allowanceAmount = 80000 }
            ledger = try store.importFiles([invoice], into: ledger, expenseID: ledger.expenses[0].id)
            let total = ledger.total, originalRow = ledger.invoiceLedgerRows[0]
            ledger = try store.duplicateLedgerRow(originalRow.id, in: ledger)
            expectEqual(ledger.invoiceCount, 2); expectEqual(ledger.total, total)
            let replacement = temporary.appendingPathComponent("替换发票.pdf")
            try makePDF(at: replacement, pages: 1, number: "26337000000777118119", amount: "241.00")
            let copiedRowID = ledger.invoiceLedgerRows[1].id
            ledger = try store.replaceLedgerRowInvoice(copiedRowID, with: replacement, in: ledger, expenseID: ledger.expenses[0].id)
            expectEqual(ledger.invoiceLedgerRows[1].invoice?.number, "26337000000777118119")
            expectEqual(ledger.invoiceLedgerRows[1].entry.reimbursementAmount, 3800)
            expectEqual(ledger.total, total)
            ledger.moveLedgerRow(copiedRowID, to: 0)
            expectEqual(ledger.invoiceLedgerRows[0].id, copiedRowID)
            ledger = store.removeLedgerRow(copiedRowID, in: ledger)!
            expectEqual(ledger.invoiceLedgerRows.count, 1)
            expectEqual(ledger.invoiceLedgerRows[0].id, originalRow.id)
            expectEqual(ledger.total, total)
            expectTrue(PDFDocument(url: store.url(for: originalRow.invoice!)) != nil)
        }
        // A failed copy cleans up only newly created files.
        var broken = claim
        let brokenIndex = broken.expenses.firstIndex { $0.id == original.id }!
        broken.expenses[brokenIndex].invoices.append(Attachment(name: "不存在.pdf", storedName: "missing.pdf"))
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Attachments").path).sorted()
        expectThrowsError(try store.duplicateExpense(original.id, in: broken))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Attachments").path).sorted(), filesBefore)
    }

    private func makeTripImportPDF(_ url: URL, lines: [String]) throws {
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor.white); context.fill(bounds)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, line) in lines.enumerated() {
            line.draw(at: NSPoint(x: 35, y: 760 - index * 65), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState(); context.endPDFPage(); context.closePDF()
    }

    @MainActor func testCompactMealInfoAndMenuNavigation() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
        let suite = "Reimbur-compact-menu-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("records", forKey: "startupPage")
        let store = ClaimStore(root: temporary)
        var meal = Claim.make(.meal)
        meal.setTravelerNames(["孙毅强"])
        meal.expenses[0].unitPrice = 3000
        meal.dates = Set((1...20).map { String(format: "2026-08-%02d", $0) })
        expectTrue(store.save(meal))
        try captureView(WorkspaceView().environmentObject(store).defaultAppStorage(defaults).preferredColorScheme(.light).tint(Palette.accent),
                        width: 1440, height: 1000, to: qa.appendingPathComponent("menu-expanded.png")) { window, host in
            @MainActor func pickers(_ view: NSView) -> [NSPopUpButton] {
                (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(pickers)
            }
            let filters = pickers(host).filter { picker in ["所有年份", "所有月份", "全部状态"].contains { picker.itemTitles.contains($0) } }
            expectEqual(filters.count, 3)
            let tops = filters.map { host.convert($0.bounds.origin, from: $0).y }
            expectLessThan((tops.max() ?? 0) - (tops.min() ?? 0), 4)
            @MainActor func snapshot(_ name: String) {
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: qa.appendingPathComponent(name))
            }
            snapshot("meal-and-filter-row.png")
            nativeClick(NSPoint(x: 100, y: 958), in: host, window: window); pumpNativeEvents(0.4)
            expectTrue(defaults.bool(forKey: "menuCollapsed"))
            snapshot("menu-icons.png")
            nativeClick(NSPoint(x: 38, y: 924), in: host, window: window)
            expectTrue(store.showSettings)
            nativeClick(NSPoint(x: 38, y: 970), in: host, window: window); pumpNativeEvents(0.4)
            expectFalse(defaults.bool(forKey: "menuCollapsed"))
            nativeClick(NSPoint(x: 80, y: 194), in: host, window: window)
            expectFalse(store.showSettings)
        }
    }

    @MainActor func testUndatedAllowanceMigrationAndIndependentAmount() throws {
        var legacy = Claim.make(.allowance, date: DayKey.date("2026-10-24")!)
        legacy.allowanceAmount = nil; legacy.invoiceLedgerEntries = nil
        legacy.setTravelerNames(["张三"])
        legacy.dates = ["2026-08-24", "2026-08-25"]
        legacy.expenses[0].unitPrice = 3000
        try Database(root: temporary).save(legacy)
        let store = ClaimStore(root: temporary)
        var claim = store.claims[0]
        expectEqual(claim.allowanceAmount, 6000)
        claim.dates = []
        expectEqual(claim.total, 6000)
        claim.allowanceAmount = 123456
        let pdf = temporary.appendingPathComponent("补助.pdf")
        try makePDF(at: pdf, pages: 1, number: "26337000000777118119", amount: "241.00")
        claim = try store.importFiles([pdf], into: claim, expenseID: claim.expenses[0].id)
        expectEqual(claim.total, 123456)
        expectEqual(claim.invoiceTotal, 24100)
        expectEqual(claim.reimbursementDayCount, 0)
        expectTrue(claim.reimbursementDates.isEmpty)
        expectFalse(claim.recordDetail.contains("天"))
        expectTrue(ClaimPeriodFilter(year: 2026, month: 10).matches(claim))
        claim.invoiceLedgerEntries?[0].reimbursementAmount = 13525
        claim.expenses[0].invoices[0].amount = 25000
        expectTrue(store.save(claim))
        expectEqual(claim.total, 123456)
        expectEqual(claim.difference, 98456)
        let reopened = ClaimStore(root: temporary).claims[0]
        expectEqual(reopened.allowanceAmount, 123456)
        expectEqual(reopened.ledgerReimbursementTotal, 13525)
        let summary = ClaimSummary.renderOverview(reopened)
        expectTrue(summary.contains("报销总额（单独填写）：1234.56"))
        expectFalse(summary.contains("天 ×"))
        expectFalse(summary.contains("日期："))
        let printFile = temporary.appendingPathComponent("undated.docx")
        try WordExporter.export(claims: [reopened], attachmentRoot: store.root.appendingPathComponent("Attachments"), to: printFile)
        let extracted = temporary.appendingPathComponent("print")
        try run("/usr/bin/ditto", ["-x", "-k", printFile.path, extracted.path])
        let xml = try String(contentsOf: extracted.appendingPathComponent("word/document.xml"), encoding: .utf8)
        expectFalse(xml.contains("天 ×"))
        expectFalse(xml.contains("尚未选择日期"))
        let removed = store.removeAttachment(reopened.expenses[0].invoices[0], from: reopened, expenseID: reopened.expenses[0].id)!
        expectEqual(removed.total, 123456)
        expectEqual(removed.invoiceCount, 0)
        expectEqual(removed.invoiceLedgerRows.count, 0)
        let fresh = Claim.make(.allowance)
        expectEqual(fresh.total, 0)
        expectEqual(fresh.allowanceAmount, 0)
    }

    @MainActor func testUndatedAllowanceEditorAndMealInfoLayout() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let store = ClaimStore(root: temporary)
        var allowance = Claim.make(.allowance)
        allowance.setTravelerNames(["孙毅强"])
        allowance.allowanceAmount = 123456
        expectTrue(store.save(allowance))
        try captureView(ClaimEditor(claim: allowance).environmentObject(store).background(Palette.canvas).tint(Palette.accent),
                        width: 950, height: 1000, to: qa.appendingPathComponent("allowance-manual-amount.png")) { window, host in
            @MainActor func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            guard let amount = fields(host).first(where: { $0.stringValue == "1234.56" }) else { fail("Manual allowance amount missing"); return }
            expectFalse(fields(host).contains { $0.stringValue == "0.00" })
            nativeClick(host.convert(NSPoint(x: amount.bounds.midX, y: amount.bounds.midY), from: amount), in: host, window: window)
            guard let editor = window.firstResponder as? NSTextView else { fail("Manual allowance amount not editable"); return }
            editor.selectAll(nil); editor.insertText("2000.00", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil); pumpNativeEvents()
            guard let purpose = fields(host).first(where: { $0.placeholderString == "填写用途，应用至清单每一行" }) else { fail("Purpose missing"); return }
            nativeClick(host.convert(NSPoint(x: purpose.bounds.midX, y: purpose.bounds.midY), from: purpose), in: host, window: window)
            (window.firstResponder as? NSTextView)?.insertText("电脑报销", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil); pumpNativeEvents()
            expectEqual(store.claims.first { $0.id == allowance.id }?.allowanceAmount, 200000)
            expectEqual(store.claims.first { $0.id == allowance.id }?.ledgerPurpose, "电脑报销")
        }
        var meal = Claim.make(.meal)
        meal.setTravelerNames(["孙毅强"])
        meal.dates = Set((1...20).map { String(format: "2026-08-%02d", $0) })
        meal.expenses[0].unitPrice = 3000
        expectTrue(store.save(meal))
        try captureView(ClaimEditor(claim: meal).environmentObject(store).background(Palette.canvas).tint(Palette.accent),
                        width: 1250, height: 1000, to: qa.appendingPathComponent("meal-compact-info.png"))
        try captureView(DashboardView(claims: store.claims, period: .constant(ClaimPeriodFilter())).background(Palette.canvas).tint(Palette.accent),
                        width: 1150, height: 900, to: qa.appendingPathComponent("dashboard-subtitle.png"))
    }

    @MainActor func testLedgerAttachmentLayoutAndCalendarEditing() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.meal)
        claim.dates = ["2026-08-24", "2026-08-25"]
        claim.expenses[0].unitPrice = 3000
        claim.setTravelerNames(["孙毅强", "张三"])
        let pdf = temporary.appendingPathComponent("餐补.pdf")
        try makePDF(at: pdf, pages: 1, number: "26337000000777118119", amount: "241.00")
        claim = try store.importFiles([pdf], into: claim, expenseID: claim.expenses[0].id)
        try captureView(ClaimEditor(claim: claim).environmentObject(store).background(Palette.canvas).tint(Palette.accent),
                        width: 1250, height: 1350, to: qa.appendingPathComponent("meal-attachments.png")) { window, host in
            @MainActor func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            let amounts = fields(host).filter { $0.stringValue == "241.00" }
                .sorted { host.convert($0.bounds.origin, from: $0).y < host.convert($1.bounds.origin, from: $1).y }
            guard amounts.count == 2, let attachmentAmount = amounts.first else { fail("Expected invoice amount and reimbursement amount in ledger row"); return }
            nativeClick(host.convert(NSPoint(x: attachmentAmount.bounds.midX, y: attachmentAmount.bounds.midY), from: attachmentAmount), in: host, window: window)
            guard let editor = window.firstResponder as? NSTextView else { fail("Attachment amount not editable"); return }
            editor.selectAll(nil); editor.insertText("250.00", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil); pumpNativeEvents()
            let saved = store.claims.first { $0.id == claim.id }!
            expectEqual(saved.invoiceLedgerRows.first?.invoice?.amount, 25000)
            expectEqual(saved.total, 6000)
            expectEqual(saved.ledgerReimbursementTotal, 24100)
            expectEqual(fields(host).filter { $0.stringValue == "250.00" }.count, 1)
        }
        var allowance = store.claims.first { $0.id == claim.id }!
        allowance.id = UUID(); allowance.kind = .allowance; allowance.title = "补助报销20260824"
        allowance.reimbursementPurpose = "电脑报销"
        try captureView(ClaimEditor(claim: allowance).environmentObject(store).background(Palette.canvas).tint(Palette.accent),
                        width: 950, height: 1350, to: qa.appendingPathComponent("allowance-attachments-compact.png"))
        let state = LedgerDateState()
        try captureView(LedgerDateInteractionView(state: state), width: 162, height: 67,
                        to: qa.appendingPathComponent("ledger-date.png")) { window, host in
            nativeClick(NSPoint(x: 80, y: 33), in: host, window: window)
            pumpNativeEvents(0.4)
            @MainActor func pickers(_ view: NSView) -> [NSDatePicker] {
                (view as? NSDatePicker).map { [$0] } ?? view.subviews.flatMap(pickers)
            }
            guard let calendar = NSApplication.shared.windows.compactMap(\.contentView).flatMap(pickers).first else { fail("Date popover calendar missing"); return }
            if let content = calendar.window?.contentView {
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: qa.appendingPathComponent("ledger-date-calendar.png"))
            }
            calendar.dateValue = DayKey.date("2026-09-05")!
            if let action = calendar.action { calendar.sendAction(action, to: calendar.target) }
            pumpNativeEvents()
            expectEqual(state.value, "2026-09-05")
        }
    }

    @MainActor func testInvoiceLedgerPreservesLegacyAmountsAndAttachments() throws {
        let database = try Database(root: temporary)
        for kind in [ClaimKind.meal, .allowance] {
            var legacy = Claim.make(kind)
            legacy.allowanceAmount = nil
            legacy.invoiceLedgerEntries = nil
            legacy.setTravelerNames(["张三"])
            legacy.dates = ["2026-10-22", "2026-10-23"]
            legacy.expenses = [Expense(kind: kind.categories[0], unitPrice: 3000, note: "保留原说明",
                                       invoices: [Attachment(name: "1.pdf", storedName: "1.pdf", amount: 50000), Attachment(name: "2.pdf", storedName: "2.pdf", amount: 20000)], claimant: "张三"),
                               Expense(kind: kind.categories[0], unitPrice: 1000, claimant: "张三")]
            legacy.status = .archived
            try database.save(legacy)
            let migrated = legacy.withInvoiceLedger
            expectEqual(migrated.total, 8000)
            expectEqual(migrated.invoiceTotal, 70000)
            expectEqual(migrated.attachments, legacy.attachments)
            expectEqual(migrated.invoiceLedgerEntries?.map(\.reimbursementAmount), [50000, 20000])
            expectEqual(migrated.invoiceLedgerRows[0].entry.detail, "保留原说明")
            expectEqual(migrated.withInvoiceLedger, migrated)
        }
        let store = ClaimStore(root: temporary)
        let reloaded = ClaimStore(root: temporary)
        expectEqual(store.claims, reloaded.claims)
        for claim in store.claims {
            expectEqual(claim.status, .archived)
            expectEqual(claim.total, 8000)
            expectEqual(claim.invoiceCount, 2)
            expectEqual(claim.invoiceLedgerRows.count, 2)
        }
        var trip = sampleClaim()
        trip.status = .pending
        expectEqual(trip.withInvoiceLedger, trip)
    }

    @MainActor func testInvoiceLedgerBatchRecognitionEditingAndDeletion() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        let first = temporary.appendingPathComponent("第一张.pdf"), second = temporary.appendingPathComponent("第二张.pdf")
        try makePDF(at: first, pages: 1, number: "26312000002517846136", amount: "241.52")
        try makePDF(at: second, pages: 1, number: "26332000003388662886", amount: "228.25")
        for kind in [ClaimKind.meal, .allowance] {
            var claim = Claim.make(kind)
            claim.setTravelerNames(["张三", "李四"])
            claim.dates = ["2026-10-23"]
            claim.expenses[0].unitPrice = 6000
            if kind == .allowance { claim.allowanceAmount = 6000 }
            claim.reimbursementPurpose = "电脑报销"
            claim = try store.importFiles([first, second], into: claim, expenseID: claim.expenses[0].id)
            expectEqual(claim.invoiceLedgerRows.count, 2)
            expectEqual(claim.invoiceLedgerRows.map { $0.invoice?.number }, ["26312000002517846136", "26332000003388662886"])
            expectEqual(claim.invoiceLedgerRows.map { $0.invoice?.amount }, [24152, 22825])
            expectEqual(claim.invoiceLedgerRows.map { $0.entry.claimant }, ["张三", "张三"])
            expectEqual(claim.total, 6000)
            expectEqual(claim.ledgerReimbursementTotal, 46977)
            expectEqual(claim.invoiceTotal, 46977)
            expectEqual(claim.ledgerPurpose, kind == .meal ? "餐补报销" : "电脑报销")
            claim.invoiceLedgerEntries?[0].reimbursementAmount = 20000
            claim.invoiceLedgerEntries?[1].reimbursementAmount = 0
            claim.invoiceLedgerEntries?[0].detail = "电脑电源 & 适配器"
            claim.invoiceLedgerEntries?[0].date = "2026-10-22"
            claim.invoiceLedgerEntries?[1].claimant = "李四"
            claim.expenses[0].invoices[0].amount = 25000
            claim.expenses[0].invoices[0].number = "00312000002517846136"
            expectTrue(claim.renameTraveler(from: "李四", to: "孙毅强"))
            expectEqual(claim.invoiceLedgerEntries?[1].claimant, "孙毅强")
            expectTrue(store.save(claim))
            expectEqual(claim.total, 6000)
            expectEqual(claim.ledgerReimbursementTotal, 20000)
            expectEqual(claim.invoiceTotal, 47825)
            let reopened = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
            expectEqual(reopened.invoiceLedgerRows[0].invoice?.number, "00312000002517846136")
            expectEqual(reopened.invoiceLedgerRows[0].entry.date, "2026-10-22")
            expectEqual(reopened.invoiceLedgerRows[0].entry.detail, "电脑电源 & 适配器")
            let summary = ClaimSummary.render(reopened)
            expectTrue(summary.contains("报销单金额：200.00"))
            expectFalse(summary.contains("个人汇总"))
            let attachment = reopened.expenses[0].invoices[0]
            claim = store.removeAttachment(attachment, from: reopened, expenseID: reopened.expenses[0].id)!
            expectEqual(claim.invoiceLedgerRows.count, 1)
            expectEqual(claim.total, 6000)
            expectEqual(claim.invoiceCount, 1)
            expectFalse(FileManager.default.fileExists(atPath: store.url(for: attachment).path))
            let retained = ClaimStore(root: store.root).claims.first { $0.id == claim.id }!
            let invalid = temporary.appendingPathComponent("错误.pdf")
            try Data("invalid pdf".utf8).write(to: invalid)
            expectThrowsError(try store.importFiles([first, invalid], into: claim, expenseID: claim.expenses[0].id))
            expectEqual(ClaimStore(root: store.root).claims.first { $0.id == claim.id }, retained)
        }
    }

    @MainActor func testInvoiceLedgerXLSXAndPrintExports() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.allowance)
        claim.setTravelerNames(["孙毅强"])
        claim.reimbursementPurpose = "电脑报销"
        claim.dates = ["2026-10-23"]
        claim.expenses[0].unitPrice = 6000
        claim.allowanceAmount = 6000
        let samples: [(String, String, Int64, Int64)] = [("26312000002517846136", "电脑电源", 24152, 24152),
                                                       ("26332000003388662886", "电脑机箱", 22825, 22825),
                                                       ("26117000000604791158", "电源适配器", 29610, 29610),
                                                       ("26312000002571444631", "交换机", 3990, 3990),
                                                       ("26332000003505153936", "内存条", 55898, 55898),
                                                       ("00337000000368119601", "油票 & 其他", 15000, 13525)]
        for sample in samples {
            let source = temporary.appendingPathComponent(sample.0 + ".pdf")
            try makePDF(at: source, pages: 1, number: sample.0, amount: Money.input(sample.2))
            claim = try store.importFiles([source], into: claim, expenseID: claim.expenses[0].id)
            let last = claim.invoiceLedgerEntries!.count - 1
            claim.invoiceLedgerEntries?[last].detail = sample.1
            claim.invoiceLedgerEntries?[last].reimbursementAmount = sample.3
        }
        let output = qa.appendingPathComponent("电脑报销清单.xlsx")
        try LedgerExporter.export(claim: claim, to: output)
        let extracted = temporary.appendingPathComponent("xlsx")
        try run("/usr/bin/ditto", ["-x", "-k", output.path, extracted.path])
        let document = try XMLDocument(contentsOf: extracted.appendingPathComponent("xl/worksheets/sheet1.xml"), options: [])
        func cell(_ address: String) throws -> XMLElement { try document.nodes(forXPath: "//*[local-name()='c' and @r='\(address)']").first as! XMLElement }
        expectEqual(try cell("D7").attribute(forName: "t")?.stringValue, "inlineStr")
        expectEqual(try cell("D7").stringValue, "00337000000368119601")
        expectEqual(try cell("E7").stringValue, "150.00")
        expectEqual(try cell("F7").stringValue, "135.25")
        expectEqual(try cell("G7").stringValue, "油票 & 其他")
        expectEqual(try cell("B2").stringValue, String(LedgerExporter.excelDate("2026-10-23")!))
        expectEqual(try document.nodes(forXPath: "//*[local-name()='c' and @r='E8']").count, 0)
        expectEqual(try document.nodes(forXPath: "//*[local-name()='c' and @r='F8']").count, 0)
        expectEqual(try document.nodes(forXPath: "//*[local-name()='autoFilter']").count, 0)
        let sheetView = try document.nodes(forXPath: "//*[local-name()='sheetView']").first as! XMLElement
        expectTrue((sheetView.attribute(forName: "showGridLines")?.stringValue ?? "1") != "0")
        expectNil(LedgerExporter.excelDate("2026-02-30"))
        let printFile = temporary.appendingPathComponent("打印.docx")
        try WordExporter.export(claims: [claim], attachmentRoot: store.root.appendingPathComponent("Attachments"), to: printFile)
        let word = temporary.appendingPathComponent("word")
        try run("/usr/bin/ditto", ["-x", "-k", printFile.path, word.path])
        let printText = try String(contentsOf: word.appendingPathComponent("word/document.xml"), encoding: .utf8)
        expectFalse(printText.contains("<w:t"))
        expectEqual(printText.components(separatedBy: "<pic:pic>").count - 1, 6)
        expectFalse(printText.contains("个人汇总"))
        try LedgerExporter.export(claim: Claim.make(.meal), to: qa.appendingPathComponent("空餐补清单.xlsx"))
        try captureView(ClaimEditor(claim: claim).environmentObject(store).background(Palette.canvas).textFieldStyle(.roundedBorder).tint(Palette.accent),
                        width: 1210, height: 1100, to: qa.appendingPathComponent("allowance-ledger.png"))
        var meal = claim
        meal.id = UUID(); meal.kind = .meal; meal.title = "餐补报销20261023"
        try LedgerExporter.export(claim: meal, to: qa.appendingPathComponent("餐补清单.xlsx"))
        try captureView(ClaimEditor(claim: meal).environmentObject(store).background(Palette.canvas).textFieldStyle(.roundedBorder).tint(Palette.accent),
                        width: 950, height: 1000, to: qa.appendingPathComponent("meal-ledger.png"))
    }

    @MainActor func testTripInvoiceLedgerAndXLSXExport() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
        let store = ClaimStore(root: temporary.appendingPathComponent("trip-ledger-db"))
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["孙毅强"])
        claim.dates = ["2026-10-23", "2026-10-24"]
        claim.tripPurpose = "宁波项目现场调试"
        claim.expenses = [Expense(kind: .train, unitPrice: 6900, origin: "杭州", destination: "宁波", claimant: "孙毅强")]
        let source = temporary.appendingPathComponent("出差火车票.pdf")
        try makeTripImportPDF(source, lines: ["电子发票（铁路电子客票）", "发票号码：26337000000388325068", "出发站：杭州东站", "到达站：宁波站", "乘车日期：2026-10-23", "票价 ¥69.00"])
        claim = try store.importFiles([source], into: claim, expenseID: claim.expenses[0].id)
        expectEqual(claim.invoiceLedgerRows.count, 1)
        expectEqual(claim.invoiceLedgerRows[0].entry.claimant, "孙毅强")
        expectEqual(claim.ledgerPurpose, "宁波项目现场调试")
        expectEqual(claim.invoiceLedgerRows[0].purpose, "宁波项目现场调试")
        expectEqual(claim.invoiceLedgerRows[0].invoice?.amount, 6900)
        expectEqual(claim.invoiceLedgerRows[0].entry.detail, "火车")
        let taxiInvoice = Attachment(name: "打车发票.pdf", storedName: "taxi.pdf", amount: 3200, number: "26337000000388325069")
        let hotelInvoice = Attachment(name: "住宿发票.pdf", storedName: "hotel.pdf", amount: 20000, number: "26337000000388325070")
        let taxi = Expense(kind: .taxi, unitPrice: 3200, invoices: [taxiInvoice], claimant: "孙毅强")
        var hotel = Expense(kind: .hotel, unitPrice: 20000, invoices: [hotelInvoice], claimant: "孙毅强")
        hotel.setTotalAmount(20000)
        claim.expenses.append(contentsOf: [hotel, taxi])
        claim.invoiceLedgerEntries?.append(InvoiceLedgerEntry(expenseID: hotel.id, invoiceID: hotelInvoice.id, date: "2026-10-24",
                                                             claimant: "孙毅强", reimbursementAmount: 20000, detail: "住宿"))
        claim.invoiceLedgerEntries?.append(InvoiceLedgerEntry(expenseID: taxi.id, invoiceID: taxiInvoice.id, date: "2026-10-23",
                                                             claimant: "孙毅强", reimbursementAmount: 3200, detail: "打车"))
        expectEqual(claim.invoiceLedgerRows.map { $0.entry.detail }, ["火车", "住宿", "打车"])
        expectEqual(claim.invoiceLedgerRowsInTypeOrder.map { $0.entry.detail }, ["火车", "打车", "住宿"])
        let output = qa.appendingPathComponent("出差报销清单.xlsx")
        try LedgerExporter.export(claim: claim, to: output)
        let extracted = temporary.appendingPathComponent("trip-ledger-xlsx")
        try run("/usr/bin/ditto", ["-x", "-k", output.path, extracted.path])
        let document = try XMLDocument(contentsOf: extracted.appendingPathComponent("xl/worksheets/sheet1.xml"), options: [])
        func cell(_ address: String) throws -> XMLElement { try document.nodes(forXPath: "//*[local-name()='c' and @r='\(address)']").first as! XMLElement }
        expectEqual(try cell("C1").stringValue, "姓名")
        expectEqual(try cell("D2").stringValue, "26337000000388325068")
        expectEqual(try cell("E2").stringValue, "69.00")
        expectEqual(try cell("G2").stringValue, "火车")
        expectEqual(try cell("G3").stringValue, "打车")
        expectEqual(try cell("G4").stringValue, "住宿")
        expectEqual(try cell("H2").stringValue, "宁波项目现场调试")
        expectEqual(try document.nodes(forXPath: "//*[local-name()='c' and @r='E5']").count, 0)
        expectEqual(try document.nodes(forXPath: "//*[local-name()='autoFilter']").count, 0)
        let sheetView = try document.nodes(forXPath: "//*[local-name()='sheetView']").first as! XMLElement
        expectTrue((sheetView.attribute(forName: "showGridLines")?.stringValue ?? "1") != "0")
        try captureView(ClaimEditor(claim: claim).environmentObject(store).background(Palette.canvas).tint(Palette.accent),
                        width: 1450, height: 1500, to: qa.appendingPathComponent("trip-ledger.png"))
    }

    @MainActor func testInvoiceLedgerNativeEditingAndStatusChart() throws {
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.meal)
        claim.dates = ["2026-10-23"]
        claim.expenses[0].unitPrice = 3000
        claim.setTravelerNames(["孙毅强"])
        let pdf = temporary.appendingPathComponent("餐补.pdf")
        try makePDF(at: pdf, pages: 1, number: "26312000002517846136", amount: "241.52")
        claim = try store.importFiles([pdf], into: claim, expenseID: claim.expenses[0].id)
        try captureView(ClaimEditor(claim: claim).environmentObject(store).background(Palette.canvas).tint(Palette.accent),
                        width: 1250, height: 1000, to: qa.appendingPathComponent("ledger-edited.png")) { window, host in
            @MainActor func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            guard let field = fields(host).first(where: { $0.placeholderString == "填写明细" }) else { fail("Ledger detail field missing"); return }
            nativeClick(host.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field), in: host, window: window)
            guard let editor = window.firstResponder as? NSTextView else { fail("Ledger detail field not editable"); return }
            editor.insertText("工作日餐补", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil); pumpNativeEvents()
            expectEqual(store.claims.first { $0.id == claim.id }?.invoiceLedgerRows[0].entry.detail, "工作日餐补")
            let amounts = fields(host).filter { $0.stringValue == "241.52" }.sorted { host.convert($0.bounds.origin, from: $0).x < host.convert($1.bounds.origin, from: $1).x }
            guard let invoiceField = amounts.first, amounts.count >= 2 else { fail("Expected separate invoice and reimbursement amounts"); return }
            nativeClick(host.convert(NSPoint(x: invoiceField.bounds.midX, y: invoiceField.bounds.midY), from: invoiceField), in: host, window: window)
            guard let amountEditor = window.firstResponder as? NSTextView else { fail("Invoice amount not editable"); return }
            amountEditor.selectAll(nil); amountEditor.insertText("250.00", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil); pumpNativeEvents()
            expectEqual(store.claims.first { $0.id == claim.id }?.invoiceTotal, 25000)
            expectEqual(store.claims.first { $0.id == claim.id }?.total, 3000)
            guard let rate = fields(host).first(where: { $0.stringValue == "30.00" }) else { fail("Daily rate field missing"); return }
            nativeClick(host.convert(NSPoint(x: rate.bounds.midX, y: rate.bounds.midY), from: rate), in: host, window: window)
            guard let rateEditor = window.firstResponder as? NSTextView else { fail("Daily rate not editable"); return }
            rateEditor.selectAll(nil); rateEditor.insertText("60.00", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil); pumpNativeEvents()
            expectEqual(store.claims.first { $0.id == claim.id }?.total, 6000)
            expectEqual(store.claims.first { $0.id == claim.id }?.invoiceTotal, 25000)
        }
        for status in [ClaimStatus.pending, .archived] {
            var record = sampleClaim(); record.id = UUID(); record.status = status
            expectTrue(store.save(record))
        }
        let plot = CGRect(x: 0, y: 0, width: 200, height: 200)
        expectEqual(DashboardChartHitTesting.status(at: CGPoint(x: 180, y: 100), plot: plot, counts: [1, 1, 1]), .unreimbursed)
        expectEqual(DashboardChartHitTesting.status(at: CGPoint(x: 100, y: 180), plot: plot, counts: [1, 1, 1]), .pending)
        expectEqual(DashboardChartHitTesting.status(at: CGPoint(x: 20, y: 100), plot: plot, counts: [1, 1, 1]), .archived)
        expectNil(DashboardChartHitTesting.status(at: CGPoint(x: 100, y: 100), plot: plot, counts: [1, 1, 1]))
        expectNil(DashboardChartHitTesting.status(at: CGPoint(x: 180, y: 100), plot: plot, counts: [0, 0, 0]))
        try captureView(DashboardView(claims: store.claims, period: .constant(ClaimPeriodFilter())).background(Palette.canvas).tint(Palette.accent),
                        width: 1150, height: 900, to: qa.appendingPathComponent("status-donut.png")) { window, host in
            window.acceptsMouseMovedEvents = true
            let location = host.convert(NSPoint(x: 1040, y: 445), to: nil)
            let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
            host.mouseEntered(with: enter)
            let move = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0)!
            host.mouseMoved(with: move); window.sendEvent(move); pumpNativeEvents(0.4)
        }
        var selected: ClaimStatus?
        try captureView(VStack(spacing: 3) {
            ForEach(ClaimStatus.allCases) { status in ClaimStatusOption(option: status, selected: status == .unreimbursed) { selected = status } }
        }.padding(8).frame(width: 176, height: 136).background(.white), width: 176, height: 136,
                        to: qa.appendingPathComponent("status-menu.png")) { window, host in
            nativeClick(NSPoint(x: 85, y: 68), in: host, window: window)
            expectEqual(selected, .pending)
            let location = host.convert(NSPoint(x: 85, y: 103), to: nil)
            let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
            host.mouseEntered(with: enter)
            let hover = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 200, clickCount: 0, pressure: 0)!
            window.acceptsMouseMovedEvents = true
            host.mouseMoved(with: hover); window.sendEvent(hover); pumpNativeEvents(0.4)
        }
    }

    @MainActor func testClaimStatusLegacyAndSQLitePersistence() throws {
        var original = sampleClaim()
        original.expenses[0].invoices = [Attachment(name: "历史发票.pdf", storedName: "old.pdf", amount: 12800)]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "savedStatus")
        let legacy = try JSONDecoder().decode(Claim.self, from: JSONSerialization.data(withJSONObject: json))
        expectEqual(legacy.status, .unreimbursed)
        expectEqual(legacy.total, original.total)
        expectEqual(legacy.attachments, original.attachments)
        let database = try Database(root: temporary)
        try database.save(legacy)
        let store = ClaimStore(root: temporary)
        expectTrue(store.ready)
        expectEqual(store.claims[0].status, .unreimbursed)
        for status in ClaimStatus.allCases.reversed() {
            expectTrue(store.setStatus(status, for: legacy.id))
            let reloaded = ClaimStore(root: temporary).claims[0]
            expectEqual(reloaded.status, status)
            expectEqual(reloaded.total, original.total)
            expectEqual(reloaded.attachments, original.attachments)
        }
        expectEqual(Claim.make(.meal).status, .unreimbursed)
        expectFalse(store.setStatus(.pending, for: UUID()))
        expectTrue(store.delete(ids: [legacy.id]))
        expectFalse(store.setStatus(.archived, for: legacy.id))
        expectTrue(store.claims.isEmpty)
    }

    func testClaimStatusFilteringStatisticsAndMetadata() {
        var trip = Claim.make(.trip, date: DayKey.date("2026-10-20")!)
        trip.title = "杭州项目"
        trip.dates = ["2026-10-21", "2026-10-22", "2026-10-23"]
        trip.setTravelerNames(["张三", "李四"])
        trip.expenses = [Expense(kind: .subsidy, unitPrice: 6000, dates: ["2026-10-21"], claimant: "张三"),
                         Expense(kind: .subsidy, unitPrice: 6000, claimant: "李四"),
                         Expense(kind: .taxi, unitPrice: 2500,
                                 invoices: [Attachment(name: "打车.pdf", storedName: "taxi.pdf", amount: 2500)],
                                 itineraries: [Attachment(name: "行程单.pdf", storedName: "route.pdf", amount: 99999)], claimant: "张三")]
        trip.status = .pending
        expectEqual(trip.recordDetail, "3天 · 2人 · 3笔 · 1份发票")
        var meal = Claim.make(.meal, date: DayKey.date("2026-10-20")!)
        meal.setTravelerNames(["张三"])
        meal.dates = ["2026-10-21", "2026-10-22"]
        meal.expenses[0].unitPrice = 3000
        var archived = Claim.make(.allowance, date: DayKey.date("2025-10-20")!)
        archived.status = .archived
        let records = [trip, meal, archived]
        expectEqual(records.filter(ClaimRecordFilter(status: .pending).matches).map(\.id), [trip.id])
        expectEqual(records.filter(ClaimRecordFilter(kind: .trip, status: .pending, period: ClaimPeriodFilter(year: 2026, month: 10), search: "李四").matches).map(\.id), [trip.id])
        expectTrue(records.filter(ClaimRecordFilter(kind: .meal, status: .pending).matches).isEmpty)
        expectTrue(records.filter(ClaimRecordFilter(status: .pending, period: ClaimPeriodFilter(year: 2025)).matches).isEmpty)
        let statistics = ClaimStatusSummary.all(in: records, period: ClaimPeriodFilter(year: 2026, month: 10))
        expectEqual(statistics.map(\.status), ClaimStatus.allCases)
        expectEqual(statistics.map { $0.records.count }, [1, 1, 0])
        expectEqual(statistics.map(\.total), [6000, 26500, 0])
        expectEqual(statistics.map(\.invoiceTotal), [0, 2500, 0])
        expectEqual(statistics.reduce(0) { $0 + $1.total }, trip.total + meal.total)
        expectEqual(ClaimStatusSummary.all(in: [], period: ClaimPeriodFilter()).map { $0.records.count }, [0, 0, 0])
    }

    @MainActor func testClaimStatusNativeEditorAndScreenshots() throws {
        let suite = "Reimbur-status-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("records", forKey: "startupPage")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaimStore(root: temporary)
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        var claim = sampleClaim()
        claim.title = "杭州项目出差"
        claim.createdAt = Date().addingTimeInterval(10)
        expectTrue(store.save(claim))
        var pending = Claim.make(.meal)
        pending.status = .pending
        pending.setTravelerNames(["张三"])
        pending.dates = ["2026-10-23"]
        pending.expenses[0].unitPrice = 3000
        expectTrue(store.save(pending))
        var archived = Claim.make(.allowance)
        archived.status = .archived
        expectTrue(store.save(archived))
        let view = WorkspaceView().environmentObject(store).defaultAppStorage(defaults).preferredColorScheme(.light).tint(Palette.accent)
        try captureView(view, width: 1440, height: 1000, to: qa.appendingPathComponent("status-records.png")) { window, host in
            nativeClick(NSPoint(x: 274, y: 381), in: host, window: window)
            pumpNativeEvents()
            guard let popover = NSApplication.shared.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
                  let content = popover.contentView else { fail("Status button did not open its choices"); return }
            nativeClick(NSPoint(x: content.bounds.midX, y: content.bounds.midY), in: content, window: popover)
            pumpNativeEvents()
            expectEqual(store.claims.first { $0.id == claim.id }?.status, .pending)
            @MainActor func titleField(_ title: String, in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.stringValue == title { return field }
                return view.subviews.lazy.compactMap { titleField(title, in: $0) }.first
            }
            guard let field = titleField(claim.title, in: host) else { fail("Missing active claim editor title field"); return }
            nativeClick(host.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field), in: host, window: window)
            guard let editor = window.firstResponder as? NSTextView else { fail("Title did not receive focus"); return }
            editor.selectAll(nil)
            editor.insertText("状态切换后继续编辑", replacementRange: NSRange(location: NSNotFound, length: 0))
            window.makeFirstResponder(nil)
            pumpNativeEvents()
            let saved = store.claims.first { $0.id == claim.id }!
            expectEqual(saved.title, "状态切换后继续编辑")
            expectEqual(saved.status, .pending)
            expectEqual(ClaimStore(root: self.temporary).claims.first { $0.id == claim.id }?.status, .pending)
            // Restore all three colors for the record-list screenshot.
            expectTrue(store.setStatus(.unreimbursed, for: claim.id))
            pumpNativeEvents()
            @MainActor func statusPicker(in view: NSView) -> NSPopUpButton? {
                if let picker = view as? NSPopUpButton, picker.itemTitles.contains("已归档") { return picker }
                return view.subviews.lazy.compactMap { statusPicker(in: $0) }.first
            }
            guard let picker = statusPicker(in: host) else { fail("Missing native status filter"); return }
            picker.menu?.performActionForItem(at: picker.indexOfItem(withTitle: "已归档"))
            pumpNativeEvents()
            expectTrue(titleField(archived.title, in: host) != nil)
            expectNil(titleField(saved.title, in: host))
            picker.menu?.performActionForItem(at: picker.indexOfItem(withTitle: "全部状态"))
            pumpNativeEvents()
            nativeClick(NSPoint(x: 300, y: 299), in: host, window: window)
            expectTrue(titleField(saved.title, in: host) != nil)
        }
        defaults.set("home", forKey: "startupPage")
        try captureView(WorkspaceView().environmentObject(store).defaultAppStorage(defaults).preferredColorScheme(.light).tint(Palette.accent),
                        width: 1440, height: 1100, to: qa.appendingPathComponent("status-dashboard.png"))
    }

    func testMoneyUsesCentsAndRejectsInvalidAmounts() {
        expectEqual(Money.parse("0.29"), 29)
        expectEqual(Money.parse("1234.56"), 123456)
        expectEqual(Money.parse("0"), 0)
        expectNil(Money.parse("-2"))
        expectNil(Money.parse("1.001"))
        expectNil(Money.parse("NaN"))
        expectNil(Money.parse("99999999999999"))
    }

    func testTripAndIndependentHotelDates() {
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三", "李四", "王五"])
        claim.dates = ["2026-10-21", "2026-10-22", "2026-10-23"]
        claim.expenses = [Expense(kind: .subsidy, unitPrice: 10000),
                          Expense(kind: .hotel, unitPrice: 32000, quantity: 2, dates: ["2026-10-21", "2026-10-22"]),
                          Expense(kind: .train, unitPrice: 25000)]
        expectEqual(claim.expenses[0].total(in: claim), 90000)
        expectEqual(claim.expenses[1].total(in: claim), 128000)
        expectEqual(claim.total, 243000)
        claim.expenses[2].invoices = [Attachment(name: "a.pdf", storedName: "a.pdf", amount: 20000, pageCount: 2)]
        expectEqual(claim.invoiceCount, 1)
        expectEqual(claim.invoiceTotal, 20000)
        expectEqual(claim.difference, 223000)
        claim.dates.removeAll()
        expectEqual(claim.expenses[0].total(in: claim), 0)
        expectEqual(claim.expenses[1].total(in: claim), 128000)
        expectEqual(claim.expenses[2].total(in: claim), 25000)
    }

    func testMealAndAllowanceIncludingNegativeDifference() {
        for kind in [ClaimKind.meal, .allowance] {
            var claim = Claim.make(kind)
            claim.dates = ["2026-10-01", "2026-10-03"]
            claim.expenses[0].unitPrice = 3050
            if kind == .allowance { claim.allowanceAmount = 6100 }
            claim.expenses[0].invoices = [Attachment(name: "a.pdf", storedName: "a.pdf", amount: 7000)]
            expectEqual(claim.total, 6100)
            expectEqual(claim.difference, -900)
        }
    }

    func testTwoDayHotelUsesOneNightAndExplicitStayDatesOverride() {
        var claim = Claim.make(.trip)
        let hotel = Expense(kind: .hotel, unitPrice: 19000, quantity: 2)
        expectEqual(hotel.days(in: claim), 0)
        claim.dates = ["2026-08-12"]
        expectEqual(hotel.total(in: claim), 0)
        claim.dates.insert("2026-08-13")
        expectEqual(hotel.days(in: claim), 1)
        expectEqual(hotel.total(in: claim), 38000)
        expectTrue(hotel.formula(in: claim).contains("1 晚"))
        expectEqual(hotel.defaultStayDates(in: claim), ["2026-08-12"])
        claim.dates.insert("2026-08-14")
        expectEqual(hotel.total(in: claim), 76000)
        var custom = hotel
        custom.dates = hotel.defaultStayDates(in: claim)
        expectEqual(custom.total(in: claim), hotel.total(in: claim))
        claim.dates = []
        expectEqual(custom.total(in: claim), 76000)
        custom.dates = []
        expectEqual(custom.total(in: claim), 0)
    }

    func testNamedExpensesAndSubsidiesReconcileWithoutDoubleCounting() {
        var claim = Claim.make(.trip)
        claim.expenses[0].unitPrice = 6000
        claim.dates = ["2026-08-12", "2026-08-13"]
        claim.setTravelerNames(["甲", "乙"])
        expectEqual(claim.expenses.map(\.claimant), ["甲", "乙"])
        expectEqual(claim.expenses.map { $0.total(in: claim) }, [12000, 12000])
        claim.addExpense(.train, unitPrice: 91000)
        expectEqual(claim.expenses.last?.claimant, "甲")
        let trainID = claim.expenses.last!.id
        claim.expenses[1].unitPrice = 6500
        claim.setTravelerNames(["甲", "乙", "丙", "丙"])
        expectEqual(claim.expenses.filter { $0.kind == .subsidy }.count, 3)
        expectEqual(claim.expenses.first { $0.claimant == "乙" }!.unitPrice, 6500)
        expectEqual(claim.expenses.first { $0.claimant == "丙" }!.total(in: claim), 12000)
        let before = claim
        claim.setTravelerNames(["甲", "乙", "丙"])
        expectEqual(claim, before)
        claim.setTravelerNames(["乙", "丙"])
        expectEqual(claim.expenses.filter { $0.kind == .subsidy }.map(\.claimant), ["乙", "丙"])
        expectEqual(claim.expenses.first { $0.id == trainID }!.claimant, "甲")
        expectEqual(claim.personBreakdowns.reduce(0) { $0 + $1.total(in: claim) }, claim.total)
        claim.expenses.removeAll { $0.kind != .subsidy }
        claim.setTravelerNames([])
        expectEqual(claim.total, 0)
        expectEqual(claim.expenses.count, 1)
        claim.setTravelerNames(["丁", "戊"])
        expectEqual(claim.expenses.count, 2)
        expectEqual(claim.total, 26000)
        claim.addExpense(.subsidy, unitPrice: 1000)
        expectEqual(claim.expenses.filter { $0.kind == .subsidy }.count, 4)
        expectEqual(claim.total, 30000)
        var meal = Claim.make(.meal)
        meal.setTravelerNames(["甲", "乙"])
        expectEqual(meal.expenses[0].claimant, "甲")
    }

    @MainActor func testLegacyPeopleMigrationPreservesInvoicesAndStableIDs() throws {
        let database = try Database(root: temporary)
        var legacy = Claim.make(.trip)
        legacy.travelerNames = ["甲", "乙"]; legacy.travelers = 2
        legacy.dates = ["2026-08-12", "2026-08-13"]
        let invoice = Attachment(name: "历史.pdf", storedName: "legacy.pdf", amount: 10000)
        try makePDF(at: database.attachmentDirectory.appendingPathComponent(invoice.storedName), pages: 1)
        legacy.expenses = [Expense(kind: .subsidy, unitPrice: 6000, invoices: [invoice]), Expense(kind: .train, unitPrice: 91000)]
        let total = legacy.total
        try database.save(legacy)
        let restored = ClaimStore(root: temporary).claims[0]
        expectEqual(restored.expenses.count, 3)
        expectEqual(restored.expenses.map(\.claimant), ["甲", "乙", "甲"])
        expectEqual(restored.expenses[0].id, legacy.expenses[0].id)
        expectEqual(restored.total, total)
        expectEqual(restored.invoiceCount, 1)
        expectEqual(restored.invoiceTotal, 10000)
        expectEqual(restored.attachments.map(\.id), [invoice.id])
        expectTrue(FileManager.default.fileExists(atPath: database.attachmentDirectory.appendingPathComponent(invoice.storedName).path))
        expectEqual(ClaimStore(root: temporary).claims[0], restored)
        var removed = restored
        removed.setTravelerNames(["乙"])
        expectEqual(removed.invoiceCount, 1)
        expectEqual(removed.personBreakdowns.reduce(0) { $0 + $1.total(in: removed) }, removed.total)
        var anonymous = legacy
        anonymous.travelerNames = nil
        expectEqual(anonymous.withPeopleAssigned.expenses, anonymous.expenses)
        expectEqual(anonymous.personBreakdowns.count, 1)
        expectEqual(anonymous.personBreakdowns[0].total(in: anonymous), anonymous.total)
    }

    func testPersonalSummaryMatchesReferenceAndSurvivesSQLite() throws {
        let claim = multiPersonClaim()
        expectEqual(claim.total, 363212)
        expectEqual(claim.invoiceCount, 20)
        let people = claim.personBreakdowns
        expectEqual(people.map { $0.total(in: claim) }, [202905, 160307])
        expectEqual(people.map(\.invoiceCount), [14, 6])
        expectEqual(people.reduce(0) { $0 + $1.invoiceTotal }, claim.invoiceTotal)
        let text = ClaimSummary.render(claim)
        expectTrue(text.contains("*总额：240.00+960.00+1820.00+422.12+190.00=3632.12"))
        let overview = ClaimSummary.renderOverview(claim)
        expectFalse(overview.contains("个人报销明细"))
        expectFalse(overview.contains("    报销人："))
        expectTrue(overview.contains("=3632.12"))
        for (person, amount) in zip(people, ["2029.05", "1603.07"]) {
            let personal = ClaimSummary.renderPerson(claim, person: person)
            expectFalse(personal.contains("个人报销明细"))
            expectFalse(personal.contains("报销人："))
            expectTrue(personal.contains("出差人：\(person.name)\n"))
            expectFalse(personal.contains("（1 人）"))
            expectTrue(personal.contains("=\(amount)"))
            expectFalse(personal.contains(person.claimant == "蔡建坤" ? "出差人：孙毅强" : "出差人：蔡建坤"))
        }
        let database = try Database(root: temporary)
        try database.save(claim)
        expectEqual(try database.load()[0], claim)
        if let directory = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try text.write(to: qa.appendingPathComponent("personal-summary.txt"), atomically: true, encoding: .utf8)
        }
    }

    @MainActor func testNativePersonalPreviewCopiesOnlySelectedPerson() throws {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let claim = multiPersonClaim()
        let person = claim.personBreakdowns[1]
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(previous) }
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try captureView(ClaimTextPreview(claim: claim, initialPersonID: person.id, close: {}).preferredColorScheme(.light).tint(Palette.accent), width: 900, height: 740, to: qa.appendingPathComponent("personal-preview.png")) { window, host in
            var sequence = 12
            @MainActor func click(_ point: NSPoint) {
                sequence += 1
                let location = host.convert(point, to: nil)
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: sequence, clickCount: 1, pressure: 0)!
                NSApplication.shared.postEvent(up, atStart: false)
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: sequence, clickCount: 1, pressure: 1)!
                NSApplication.shared.sendEvent(down)
                let end = Date().addingTimeInterval(0.35)
                while Date() < end {
                    if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true), ![NSEvent.EventType.keyDown, .keyUp, .flagsChanged].contains(event.type) { NSApplication.shared.sendEvent(event) }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                }
            }
            click(NSPoint(x: 867, y: 33))
            expectEqual(pasteboard.string(forType: .string), ClaimSummary.renderPerson(claim, person: person))
            click(NSPoint(x: 46, y: 92))
            click(NSPoint(x: 867, y: 33))
            expectEqual(pasteboard.string(forType: .string), ClaimSummary.renderOverview(claim))
            expectFalse(pasteboard.string(forType: .string)?.contains("个人报销明细") ?? true)
            click(NSPoint(x: 106, y: 92))
            click(NSPoint(x: 867, y: 33))
            expectEqual(pasteboard.string(forType: .string), ClaimSummary.renderPerson(claim, person: claim.personBreakdowns[0]))
            click(NSPoint(x: 180, y: 92))
        }
    }

    func testSQLiteRoundTripUpdateAndDelete() throws {
        let db = try Database(root: temporary)
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三"])
        claim.title = "上海 → 杭州 '项目' & 测试"
        claim.note = "第一行\n第二行"
        claim.dates = ["2026-10-21"]
        try db.save(claim)
        expectEqual(try Database(root: temporary).load(), [claim])
        claim.expenses[0].unitPrice = 12345
        try db.save(claim)
        expectEqual(try db.load().count, 1)
        expectEqual(try db.load()[0].total, 12345)
        try db.delete(claim.id)
        expectTrue(try db.load().isEmpty)
    }

    func testCalendarRoundTripAcrossLeapDay() {
        expectEqual(DayKey.string(DayKey.date("2028-02-29")!), "2028-02-29")
        expectEqual(DayKey.string(DayKey.date("2026-12-31")!), "2026-12-31")
    }

    func testDefaultDateTitleAllowsDuplicateNames() throws {
        let date = DayKey.date("2026-10-23")!
        let first = Claim.make(.trip, date: date)
        let second = Claim.make(.meal, date: date)
        let duplicate = Claim.make(.trip, date: date)
        expectEqual(first.title, "出差报销20261023")
        expectEqual(second.title, "餐补报销20261023")
        expectEqual(Claim.make(.allowance, date: date).title, "补贴报销20261023")
        expectEqual(duplicate.title, first.title)
        expectFalse(first.id == second.id)
        let database = try Database(root: temporary)
        try database.save(first)
        try database.save(second)
        try database.save(duplicate)
        let restored = try Database(root: temporary).load()
        expectEqual(restored.count, 3)
        expectEqual(restored.filter { $0.title == "出差报销20261023" }.count, 2)
    }

    func testExpenseGroupsAggregateWithoutMergingEntries() throws {
        var claim = Claim.make(.trip)
        claim.expenses += [Expense(kind: .train, unitPrice: 10000, origin: "上海", destination: "杭州"),
                           Expense(kind: .taxi, unitPrice: 2000),
                           Expense(kind: .train, unitPrice: 25000, origin: "杭州", destination: "南京"),
                           Expense(kind: .taxi, unitPrice: 3000)]
        claim.expenses[1].invoices = [Attachment(name: "a.pdf", storedName: "a.pdf", amount: 8000)]
        claim.expenses[3].invoices = [Attachment(name: "b.pdf", storedName: "b.pdf", amount: 24000)]
        let database = try Database(root: temporary)
        try database.save(claim)
        let restored = try database.load()[0]
        expectEqual(restored.expenseGroups.count, 3)
        let trains = restored.expenseGroups.first { $0.kind == .train }!
        expectEqual(trains.expenses.map(\.id), [claim.expenses[1].id, claim.expenses[3].id])
        expectEqual(trains.expenses.map(\.destination), ["杭州", "南京"])
        expectEqual(trains.total(in: restored), 35000)
        expectEqual(trains.invoiceCount, 2)
        expectEqual(trains.invoiceTotal, 32000)
        expectEqual(restored.expenseGroups.first { $0.kind == .taxi }!.total(in: restored), 5000)
        expectEqual(restored.expenseGroups.reduce(0) { $0 + $1.total(in: restored) }, restored.total)
    }

    func testExpenseOrderPersistsAndLegacyRecordsKeepDefaultOrder() throws {
        var claim = sampleClaim()
        claim.expenses.append(Expense(kind: .train, unitPrice: 1200))
        let entries = claim.expenses
        let total = claim.total
        claim.moveExpenseGroup(.subsidy, to: 2)
        expectEqual(claim.expenseGroups.map(\.kind), [.train, .hotel, .subsidy])
        claim.moveExpenseGroup(.subsidy, to: 0)
        expectEqual(claim.expenseGroups.map(\.kind), [.subsidy, .train, .hotel])
        claim.moveExpenseGroup(.hotel, to: -1)
        claim.moveExpenseGroup(.hotel, to: 10)
        claim.moveExpenseGroup(.train, to: 0)
        let database = try Database(root: temporary)
        try database.save(claim)
        let restored = try database.load()[0]
        expectEqual(restored.expenseGroups.map(\.kind), [.train, .subsidy, .hotel])
        expectEqual(restored.expenses, entries)
        expectEqual(restored.total, total)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(claim)) as! [String: Any]
        object.removeValue(forKey: "expenseOrder")
        let legacy = try JSONDecoder().decode(Claim.self, from: JSONSerialization.data(withJSONObject: object))
        expectEqual(legacy.expenseGroups.map(\.kind), [.subsidy, .train, .hotel])
    }

    @MainActor func testDefaultPricesOnlyApplyToNewExpenses() throws {
        let suite = "Reimbur-default-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expectEqual(ExpenseDefaults.saved(in: defaults), ExpenseDefaults())
        defaults.set(10025, forKey: "defaultSubsidy")
        defaults.set(3050, forKey: "defaultMeal")
        defaults.set(-100, forKey: "defaultAllowance")
        defaults.set(32000, forKey: "defaultHotel")
        let prices = ExpenseDefaults.saved(in: defaults)
        expectEqual(prices.price(for: .hotel), 0)
        expectEqual(prices.price(for: .train), 0)
        expectEqual(prices.price(for: .allowance), 0)
        let store = ClaimStore(root: temporary)
        let first = store.create(.trip, defaults: prices)!
        _ = store.create(.meal, defaults: prices)
        defaults.set(99999, forKey: "defaultSubsidy")
        let second = store.create(.trip, defaults: ExpenseDefaults.saved(in: defaults))!
        let restored = ClaimStore(root: temporary)
        expectEqual(restored.claims.first { $0.id == first }!.expenses[0].unitPrice, 10025)
        expectEqual(restored.claims.first { $0.id == second }!.expenses[0].unitPrice, 99999)
        expectEqual(restored.claims.first { $0.kind == .meal }!.expenses[0].unitPrice, 3050)
    }

    @MainActor func testInvoiceDeletionPersistsAndPreservesOtherAttachments() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.allowance)
        let source = temporary.appendingPathComponent("发票.pdf")
        try makePDF(at: source, pages: 1)
        claim = try store.importFiles([source, source], into: claim, expenseID: claim.expenses[0].id)
        claim.expenses[0].invoices[0].amount = 10000
        claim.expenses[0].invoices[1].amount = 20000
        expectTrue(store.save(claim))
        let removed = claim.expenses[0].invoices[0]
        let retained = claim.expenses[0].invoices[1]
        // This is the same one-step operation used by the invoice trash button.
        claim = store.removeAttachment(removed, from: claim, expenseID: claim.expenses[0].id)!
        expectEqual(claim.invoiceCount, 1)
        expectEqual(claim.invoiceTotal, 20000)
        expectFalse(FileManager.default.fileExists(atPath: store.url(for: removed).path))
        expectTrue(FileManager.default.fileExists(atPath: store.url(for: retained).path))
        let restored = ClaimStore(root: store.root).claims[0]
        expectEqual(restored.invoiceCount, 1)
        expectEqual(restored.expenses[0].invoices[0].id, retained.id)
        // A stale or mismatched deletion must not delete another expense's file.
        expectNil(store.removeAttachment(retained, from: claim, expenseID: UUID()))
        expectTrue(FileManager.default.fileExists(atPath: store.url(for: retained).path))
    }

    @MainActor func testSubsidyRejectsNewInvoicesAndPreservesLegacyAttachments() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip)
        claim.expenses[0].kind = .train
        let source = temporary.appendingPathComponent("旧版发票.pdf")
        try makePDF(at: source, pages: 1)
        claim = try store.importFiles([source], into: claim, expenseID: claim.expenses[0].id)
        claim.expenses[0].kind = .subsidy
        expectTrue(store.save(claim))
        expectThrowsError(try store.importFiles([source], into: claim, expenseID: claim.expenses[0].id))
        let restored = ClaimStore(root: store.root).claims[0]
        expectEqual(restored.expenses[0].kind, .subsidy)
        expectEqual(restored.invoiceCount, 1)
        expectTrue(FileManager.default.fileExists(atPath: store.url(for: restored.expenses[0].invoices[0]).path))
    }

    @MainActor func testNativePreviewLoadsPagesAndImages() throws {
        let pdf = temporary.appendingPathComponent("预览.pdf")
        try makePDF(at: pdf, pages: 2)
        let pdfSession = AttachmentPreviewSession(url: pdf)
        expectNil(pdfSession.errorMessage)
        expectEqual(pdfSession.pageCount, 2)
        expectTrue(pdfSession.image != nil)
        expectTrue(hasVisibleInk(pdfSession.image!))
        pdfSession.movePage(1)
        expectEqual(pdfSession.pageNumber, 2)
        expectTrue(hasVisibleInk(pdfSession.image!))
        pdfSession.movePage(-1)
        expectEqual(pdfSession.pageNumber, 1)
        let cover = temporary.appendingPathComponent("预览.png")
        try makeCover(at: cover)
        let imageSession = AttachmentPreviewSession(url: cover)
        expectNil(imageSession.errorMessage)
        expectTrue(imageSession.image != nil)
        let invalid = AttachmentPreviewSession(url: temporary.appendingPathComponent("missing.png"))
        expectTrue(invalid.errorMessage != nil)
        if let directory = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            let invoice = Attachment(name: "预览.pdf", storedName: "预览.pdf")
            let form = Attachment(name: "预览.png", storedName: "预览.png")
            try captureView(AttachmentPreview(request: PreviewRequest(attachment: invoice, url: pdf)), width: 1000, height: 740, to: qa.appendingPathComponent("pdf-preview.png"))
            try captureView(AttachmentPreview(request: PreviewRequest(attachment: form, url: cover)), width: 1000, height: 740, to: qa.appendingPathComponent("image-preview.png"))
        }
    }

    @MainActor func testDifferentPersonalDatesUseLongestDuration() throws {
        var claim = Claim.make(.trip)
        claim.dates = Set((1...5).map { "2026-10-0\($0)" })
        claim.setTravelerNames(["张三", "李四"])
        claim.expenses[0].unitPrice = 10000
        claim.expenses[0].dates = ["2026-10-01", "2026-10-02"]
        claim.expenses[1].unitPrice = 10000
        claim.expenses[1].dates = ["2026-10-10", "2026-10-11", "2026-10-12"]
        claim.addExpense(.train, unitPrice: 20000)
        claim.addExpense(.hotel, unitPrice: 10000)
        expectEqual(claim.personBreakdowns.map { $0.days(in: claim) }, [2, 3])
        expectEqual(claim.reimbursementDayCount, 3)
        expectTrue(ClaimSummary.renderOverview(claim).contains("日期：2026-10-01~2026-10-02、2026-10-10~2026-10-12（3 天）"))
        let text = ClaimSummary.renderPerson(claim, person: claim.personBreakdowns[1])
        expectTrue(text.contains("2026-10-10~2026-10-12（3 天）"))
        expectFalse(text.contains("个人报销明细"))
        expectFalse(text.contains("报销人："))
        let store = ClaimStore(root: temporary)
        expectTrue(store.save(claim))
        if let directory = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: directory)
            try captureView(ClaimEditor(claim: claim).environmentObject(store).background(Palette.canvas).tint(Palette.accent), width: 1000, height: 1480, to: qa.appendingPathComponent("statistics-and-days.png"))
        }
        var empty = Claim.make(.trip)
        expectEqual(empty.reimbursementDayCount, 0)
        empty.dates = ["2026-10-24"]
        expectEqual(empty.reimbursementDayCount, 1)
    }

    @MainActor func testGalleryNavigationCopyDownloadAndCanvas() throws {
        let pdf = temporary.appendingPathComponent("第一份.pdf")
        let png = temporary.appendingPathComponent("报销单.png")
        try makePDF(at: pdf, pages: 2)
        try makeCover(at: png)
        let invoice = Attachment(name: pdf.lastPathComponent, storedName: pdf.lastPathComponent)
        let cover = Attachment(name: png.lastPathComponent, storedName: png.lastPathComponent)
        let request = PreviewRequest(attachments: [invoice, cover], selected: invoice, attachmentRoot: temporary)
        let session = AttachmentPreviewSession(request: request)
        expectFalse(session.canMovePrevious)
        session.move(1); expectEqual(session.pageNumber, 2)
        session.move(1); expectEqual(session.item.attachment.id, cover.id)
        expectFalse(session.canMoveNext)
        session.move(-1); expectEqual(session.item.attachment.id, invoice.id)
        expectEqual(session.pageNumber, 2)
        let board = NSPasteboard(name: NSPasteboard.Name("Reimbur-gallery-\(UUID())"))
        defer { board.releaseGlobally() }
        expectTrue(session.copy(to: board))
        expectEqual(board.string(forType: .fileURL), pdf.absoluteString)
        expectTrue(board.canReadObject(forClasses: [NSImage.self], options: nil))
        let saved = temporary.appendingPathComponent("下载.pdf")
        try Data("existing".utf8).write(to: saved)
        try session.saveCopy(to: saved)
        expectEqual(try Data(contentsOf: saved), try Data(contentsOf: pdf))
        let initialImage = AttachmentPreviewSession(request: PreviewRequest(attachments: [invoice, cover], selected: cover, attachmentRoot: temporary))
        expectEqual(initialImage.item.attachment.id, cover.id)
        let missing = Attachment(name: "丢失.png", storedName: "丢失.png")
        let broken = AttachmentPreviewSession(request: PreviewRequest(attachments: [cover, missing, invoice], selected: missing, attachmentRoot: temporary))
        expectTrue(broken.errorMessage != nil)
        broken.move(1); expectEqual(broken.item.attachment.id, invoice.id)
        expectNil(broken.errorMessage)

        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try captureView(AttachmentPreview(request: request).tint(Palette.accent), width: 1000, height: 740, to: qa.appendingPathComponent("gallery-preview.png")) { window, host in
            @MainActor func canvas(in view: NSView) -> AttachmentCanvasView? {
                if let view = view as? AttachmentCanvasView { return view }
                return view.subviews.lazy.compactMap { canvas(in: $0) }.first
            }
            guard let view = canvas(in: host) else { fail("Missing attachment canvas"); return }
            expectEqual(view.contentID, "\(invoice.id)-1")
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 45, wheel2: 0, wheel3: 0)!
            wheel.location = CGPoint(x: 500, y: 400)
            view.scrollWheel(with: NSEvent(cgEvent: wheel)!)
            expectTrue(view.zoom > 1)
            @MainActor func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 100, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, NSPoint(x: 450, y: 300)))
            view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 480, y: 330)))
            view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 480, y: 330)))
            expectFalse(view.pan == .zero)
            nativeClick(NSPoint(x: 500, y: 400), in: host, window: window, count: 2)
            expectEqual(view.zoom, 1)
            expectEqual(view.pan, .zero)
            let menu = view.menu(for: event(.rightMouseDown, .zero))
            expectEqual(menu?.items.map(\.title), ["复制", "下载"])
            expectTrue(menu?.items.allSatisfy { $0.image != nil } == true)
            nativeClick(NSPoint(x: 970, y: 400), in: host, window: window)
            expectEqual(canvas(in: host)?.contentID, "\(invoice.id)-2")
            nativeClick(NSPoint(x: 970, y: 400), in: host, window: window)
            expectEqual(canvas(in: host)?.contentID, "\(cover.id)-1")
            nativeClick(NSPoint(x: 30, y: 400), in: host, window: window)
            expectEqual(canvas(in: host)?.contentID, "\(invoice.id)-2")
            nativeClick(NSPoint(x: 879, y: 31), in: host, window: window)
            expectEqual(canvas(in: host)?.contentID, "\(cover.id)-1")
        }
    }

    @MainActor func testCalendarCellCornersAndSweep() throws {
        let state = InteractionState()
        let view = CalendarPicker(selection: Binding(get: { state.dates }, set: { state.dates = $0 }))
            .padding(20).background(.white).tint(Palette.accent)
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try captureView(view, width: 320, height: 340, to: qa.appendingPathComponent("calendar-cells.png")) { window, host in
            // Cell corners deliberately avoid the centered numeral.
            nativeClick(NSPoint(x: 141, y: 71), in: host, window: window)
            expectTrue(state.dates.contains("2026-10-01") == false)
            let number = window.windowNumber
            let forward: [CGFloat] = (1...20).map { 181.0 + CGFloat($0) * 4.0 }
            let backward: [CGFloat] = (1...20).map { 261.0 - CGFloat($0) * 4.0 }
            let xs = forward + backward
            let points = xs.map { host.convert(NSPoint(x: $0, y: 71), to: nil) }
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.001)
                for (index, point) in points.enumerated() {
                    let type: NSEvent.EventType = index == points.count - 1 ? .leftMouseUp : .leftMouseDragged
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: 700, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                    NSApplication.shared.postEvent(event, atStart: false)
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: host.convert(NSPoint(x: 181, y: 71), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: 700, clickCount: 1, pressure: 1)!
            NSApplication.shared.sendEvent(down)
            pumpNativeEvents(0.9)
            expectTrue(state.dates.isEmpty)
        }
    }

    @MainActor func testImportCopiesFilesAndRollsBackInvalidBatch() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.allowance)
        expectTrue(store.save(claim))
        let source = temporary.appendingPathComponent("valid.pdf")
        try makePDF(at: source, pages: 2)
        let invalid = temporary.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        expectThrowsError(try store.importFiles([source, invalid], into: claim, expenseID: claim.expenses[0].id))
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("Attachments").path).count, 0)
        expectEqual(store.claims[0].invoiceCount, 0)
        claim = try store.importFiles([source], into: claim, expenseID: claim.expenses[0].id)
        expectEqual(claim.invoiceCount, 1)
        expectEqual(claim.expenses[0].invoices[0].pageCount, 2)
        try FileManager.default.removeItem(at: source)
        let copied = store.url(for: claim.expenses[0].invoices[0])
        expectTrue(FileManager.default.fileExists(atPath: copied.path))
        expectEqual(ClaimStore(root: store.root).claims[0].invoiceCount, 1)
        expectTrue(store.delete(claim))
        expectFalse(FileManager.default.fileExists(atPath: copied.path))
    }

    func testAttachmentOnlyPrintLayout() throws {
        var claim = sampleClaim()
        let train = temporary.appendingPathComponent("火车票.pdf")
        try makePDF(at: train, pages: 2)
        let cover = temporary.appendingPathComponent("报销单.png")
        try makeCover(at: cover)
        let invoice = temporary.appendingPathComponent("打车发票.pdf")
        try makePDF(at: invoice, pages: 1)
        let itinerary = temporary.appendingPathComponent("行程单.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(itinerary as CFURL, mediaBox: &bounds, nil)!
        for page in 0..<2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.white.setFill(); bounds.fill()
            let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]
            "行程单 第 \(page + 1) 页".draw(at: NSPoint(x: 50, y: 770), withAttributes: style)
            "上海虹桥 → 公司  合计 ¥38.00".draw(at: NSPoint(x: 50, y: 640), withAttributes: style)
            if page == 1 {
                // Print should favour the header and discard the lower footer.
                "底部说明 应裁掉".draw(at: NSPoint(x: 50, y: 45), withAttributes: style)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        let itineraryPDF = PDFDocument(url: itinerary)!
        let scanned = itineraryPDF.page(at: 0)!.thumbnail(of: NSSize(width: 1190, height: 1684), for: .mediaBox)
        let screenshot = temporary.appendingPathComponent("行程截图.png")
        try NSBitmapImageRep(data: scanned.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: screenshot)
        claim.covers = [Attachment(name: "报销单.png", storedName: "报销单.png")]
        var taxi = Expense(kind: .taxi, unitPrice: 3800)
        taxi.invoices = [Attachment(name: "打车发票.pdf", storedName: "打车发票.pdf")]
        taxi.itineraries = [Attachment(name: "行程单.pdf", storedName: "行程单.pdf"), Attachment(name: "行程截图.png", storedName: "行程截图.png")]
        var rail = Expense(kind: .train, unitPrice: 55300)
        rail.invoices = [Attachment(name: "火车票.pdf", storedName: "火车票.pdf")]
        claim.expenses = [rail, taxi]
        let output = temporary.appendingPathComponent("附件打印.docx")
        try WordExporter.export(claims: [claim], attachmentRoot: temporary, to: output)
        let xml = try unzip(output, entry: "word/document.xml")
        let document = try XMLDocument(xmlString: xml)
        expectEqual(try document.nodes(forXPath: "//*[local-name()='t']").count, 0)
        expectEqual(try document.nodes(forXPath: "//*[local-name()='tbl']").count, 0)
        let anchors = try document.nodes(forXPath: "//*[local-name()='anchor']")
        expectEqual(anchors.count, 9) // cover + four rail placements + invoice + two PDF pages + image
        let refs = try document.nodes(forXPath: "//*[local-name()='blip']/@*[local-name()='embed']").map { $0.stringValue! }
        expectEqual(refs, ["rIdImage1", "rIdImage2", "rIdImage2", "rIdImage3", "rIdImage3", "rIdImage4", "rIdImage5", "rIdImage6", "rIdImage7"])
        expectEqual(try document.nodes(forXPath: "//*[local-name()='pageBreakBefore']").count, 4)
        for (index, anchor) in anchors.enumerated() {
            let extent = try anchor.nodes(forXPath: "./*[local-name()='extent']").first as! XMLElement
            let height = Int(extent.attribute(forName: "cy")!.stringValue!)!
            let y = Int(try anchor.nodes(forXPath: "./*[local-name()='positionV']/*[local-name()='posOffset']").first!.stringValue!)!
            let expectedCenter = 284 * 635 + (index % 2) * 8135 * 635 + 8135 * 635 / 2
            expectTrue(abs(y + height / 2 - expectedCenter) <= 1)
            expectTrue(height <= (8135 - 160) * 635)
        }
        let unpacked = temporary.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", output.path, unpacked.path])
        func bitmap(_ number: Int) -> NSBitmapImageRep { NSBitmapImageRep(data: try! Data(contentsOf: unpacked.appendingPathComponent("word/media/image\(number).jpg")))! }
        expectTrue(bitmap(1).pixelsHigh > bitmap(1).pixelsWide) // portrait cover remains intact
        expectTrue(abs(Double(bitmap(2).pixelsHigh) / Double(bitmap(2).pixelsWide) - 595.0 / 842) < 0.01)
        for number in 5...7 {
            expectEqual(bitmap(number).pixelsWide, 2400)
            expectEqual(bitmap(number).pixelsHigh, 1697)
        }
        for entry in ["[Content_Types].xml", "_rels/.rels", "word/styles.xml", "word/_rels/document.xml.rels"] {
            expectNoThrow(try XMLDocument(xmlString: unzip(output, entry: entry)))
        }
        // No attachments must not produce a blank or explanatory document.
        expectThrowsError(try WordExporter.export(claims: [Claim.make(.meal)], attachmentRoot: temporary, to: temporary.appendingPathComponent("empty.docx")))
        // Batch export keeps both records' attachments, with no title or separator pages.
        let batch = temporary.appendingPathComponent("批量.docx")
        try WordExporter.export(claims: [claim, claim], attachmentRoot: temporary, to: batch)
        let batchDocument = try XMLDocument(xmlString: unzip(batch, entry: "word/document.xml"))
        expectEqual(try batchDocument.nodes(forXPath: "//*[local-name()='anchor']").count, 18)
        expectEqual(try batchDocument.nodes(forXPath: "//*[local-name()='pageBreakBefore']").count, 8)
        expectEqual(try batchDocument.nodes(forXPath: "//*[local-name()='t']").count, 0)
        if let directory = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try Data(contentsOf: output).write(to: qa.appendingPathComponent("attachment-print.docx"))
            // A single attachment verifies the odd final page has no spurious extra page.
            var single = claim; single.expenses = []
            try WordExporter.export(claims: [single], attachmentRoot: temporary, to: qa.appendingPathComponent("single-print.docx"))
        }
    }

    func testExportFailurePreservesExistingFile() throws {
        var claim = Claim.make(.meal)
        claim.expenses[0].invoices = [Attachment(name: "missing.pdf", storedName: "missing.pdf")]
        let output = temporary.appendingPathComponent("existing.docx")
        try Data("original".utf8).write(to: output)
        expectThrowsError(try WordExporter.export(claims: [claim], attachmentRoot: temporary, to: output))
        expectEqual(try String(contentsOf: output, encoding: .utf8), "original")
    }

    func testTravelerTagsAndLegacyDecoding() throws {
        var claim = Claim.make(.trip)
        expectEqual(claim.travelerCount, 0)
        claim.setTravelerNames([" 张三 ", "李四", "张三", " "])
        expectEqual(claim.travelerNames, ["张三", "李四"])
        expectEqual(claim.travelers, 2)
        claim.dates = ["2026-10-01", "2026-10-02"]
        for index in claim.expenses.indices { claim.expenses[index].unitPrice = 5000 }
        expectEqual(claim.total, 20000)
        claim.setTravelerNames(["李四"])
        expectEqual(claim.total, 10000)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(claim)) as! [String: Any]
        object.removeValue(forKey: "travelerNames")
        object["travelers"] = 3
        object["expenses"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([Expense(kind: .subsidy, unitPrice: 5000)]))
        let legacy = try JSONDecoder().decode(Claim.self, from: JSONSerialization.data(withJSONObject: object))
        expectNil(legacy.travelerNames)
        expectEqual(legacy.travelerCount, 3)
        expectEqual(legacy.total, 30000)
    }

    func testPeriodFilterAndTextSummary() {
        var claim = Claim.make(.trip, date: DayKey.date("2025-12-12")!)
        claim.setTravelerNames(["张三", "李四"])
        claim.dates = ["2026-09-30", "2026-10-01", "2026-10-03"]
        expectTrue(ClaimPeriodFilter(year: 2026, month: 9).matches(claim))
        expectFalse(ClaimPeriodFilter(year: 2026, month: 10).matches(claim))
        expectTrue(ClaimPeriodFilter(month: 9).matches(claim))
        expectEqual(ClaimSummary.ranges(claim.dates), "2026-09-30~2026-10-01、2026-10-03")
        claim.expenses = [Expense(kind: .subsidy, unitPrice: 5000),
                          Expense(kind: .train, unitPrice: 8500, origin: "宁波", destination: "杭州"),
                          Expense(kind: .train, unitPrice: 6200, origin: "宁波", destination: "杭州")]
        claim.expenses[1].invoices = [Attachment(name: "票.pdf", storedName: "票.pdf", amount: 8500)]
        let text = ClaimSummary.render(claim)
        expectTrue(text.contains("出差人：张三、李四（2 人）"))
        expectTrue(text.contains("宁波-杭州：85.00+62.00=147.00"))
        expectTrue(text.contains("*总额：300.00+147.00=447.00"))
        expectTrue(text.contains("*总数：1 张"))
        claim.dates = []
        expectTrue(ClaimPeriodFilter(year: 2025, month: 12).matches(claim))
    }

    func testCalendarSweepIsIdempotentAndSupportsErasing() {
        var selection: Set<String> = ["01", "03"]
        var paint = CalendarPaintSelection()
        for key in ["02", "03", "04", "04", "03", "02"] { paint.visit(key, selection: &selection) }
        expectEqual(selection, ["01", "03"])
        paint.visit("04", selection: &selection)
        expectEqual(selection, ["01", "02", "03", "04"])
        paint = CalendarPaintSelection()
        for key in ["02", "03", "04"] { paint.visit(key, selection: &selection) }
        expectEqual(selection, ["01"])
        paint.visit("02", selection: &selection)
        expectEqual(selection, ["01", "02", "03", "04"])
        paint.visit("03", selection: &selection)
        expectEqual(selection, ["01", "04"])
    }

    func testTravelerRenamePreservesExpenses() throws {
        var claim = multiPersonClaim()
        let before = claim
        expectTrue(claim.renameTraveler(from: "蔡建坤", to: " 蔡先生 "))
        expectEqual(claim.travelerNames, ["蔡先生", "孙毅强"])
        expectEqual(claim.total, before.total)
        expectEqual(claim.invoiceTotal, before.invoiceTotal)
        expectEqual(claim.personBreakdowns.map { $0.total(in: claim) }, before.personBreakdowns.map { $0.total(in: before) })
        expectEqual(claim.expenses.map(\.id), before.expenses.map(\.id))
        var expected = before.expenses
        for index in expected.indices where expected[index].claimant == "蔡建坤" { expected[index].claimant = "蔡先生" }
        expectEqual(claim.expenses, expected)
        let renamed = claim
        expectFalse(claim.renameTraveler(from: "蔡先生", to: "孙毅强"))
        expectFalse(claim.renameTraveler(from: "蔡先生", to: " "))
        expectEqual(claim, renamed)
        let database = try Database(root: temporary)
        try database.save(claim)
        expectEqual(try database.load()[0], renamed)
    }

    @MainActor func testNativeTravelerDoubleClickRename() throws {
        let state = InteractionState()
        let extraNames = (1...7).map { "报销人\($0)" }
        state.names = ["张三", "李四"] + extraNames
        let view = VStack {
            PeopleTagInput(names: Binding(get: { state.names }, set: { state.names = $0 }))
            Color.clear.frame(height: 60).contentShape(Rectangle())
        }.padding(20).frame(width: 500, height: 140).background(.white)
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try captureView(view, width: 500, height: 140, to: qa.appendingPathComponent("traveler-rename.png")) { window, host in
            nativeClick(NSPoint(x: 45, y: 36), in: host, window: window)
            nativeClick(NSPoint(x: 45, y: 36), in: host, window: window, count: 2)
            guard let editor = window.firstResponder as? NSTextView else { fail("Double-click must focus inline name editor"); return }
            editor.selectAll(nil); editor.insertText("张先生", replacementRange: NSRange(location: NSNotFound, length: 0))
            pumpNativeEvents(); editor.insertNewline(nil); pumpNativeEvents()
            expectEqual(state.names, ["张先生", "李四"] + extraNames)
            nativeClick(NSPoint(x: 45, y: 36), in: host, window: window)
            nativeClick(NSPoint(x: 45, y: 36), in: host, window: window, count: 2)
            guard let editor = window.firstResponder as? NSTextView else { fail("Second double-click must focus inline editor"); return }
            editor.selectAll(nil); editor.insertText("张女士", replacementRange: NSRange(location: NSNotFound, length: 0))
            pumpNativeEvents()
            nativeClick(NSPoint(x: 350, y: 105), in: host, window: window)
            expectEqual(state.names, ["张女士", "李四"] + extraNames)
        }
    }

    func testDashboardSectorHoverHitTesting() {
        let plot = CGRect(x: 20, y: 30, width: 200, height: 200)
        let values: [Int64] = [100, 200, 100]
        expectEqual(DashboardChartHitTesting.kind(at: CGPoint(x: 176, y: 74), plot: plot, values: values), .trip)
        expectEqual(DashboardChartHitTesting.kind(at: CGPoint(x: 120, y: 210), plot: plot, values: values), .meal)
        expectEqual(DashboardChartHitTesting.kind(at: CGPoint(x: 64, y: 74), plot: plot, values: values), .allowance)
        expectNil(DashboardChartHitTesting.kind(at: CGPoint(x: 120, y: 130), plot: plot, values: values))
        expectNil(DashboardChartHitTesting.kind(at: CGPoint(x: 5, y: 130), plot: plot, values: values))
        expectNil(DashboardChartHitTesting.kind(at: CGPoint(x: 176, y: 74), plot: plot, values: [0, 0, 0]))
        expectEqual(DashboardChartHitTesting.kind(at: CGPoint(x: 176, y: 74), plot: plot, values: [0, 100, 0]), .meal)
    }

    @MainActor func testNativeDashboardHover() throws {
        var meal = Claim.make(.meal)
        meal.dates = ["2026-10-02", "2026-10-03"]
        meal.expenses[0].unitPrice = 10000
        let view = DashboardView(claims: [sampleClaim(), meal], period: .constant(ClaimPeriodFilter(year: 2026)))
            .frame(width: 1150, height: 800).background(Palette.canvas)
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try captureView(view, width: 1150, height: 800, to: qa.appendingPathComponent("dashboard-hover.png")) { window, host in
            window.acceptsMouseMovedEvents = true
            @MainActor func hover(_ point: NSPoint) {
                let location = host.convert(point, to: nil)
                let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
                host.mouseEntered(with: enter)
                let move = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0)!
                host.mouseMoved(with: move)
                pumpNativeEvents(0.4)
            }
            hover(NSPoint(x: 593, y: 440))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])!.write(to: qa.appendingPathComponent("dashboard-monthly-hover.png"))
            hover(NSPoint(x: 1040, y: 450))
        }
    }

    func testTooltipAvoidsMarksAndFollowsCursor() {
        let bounds = CGSize(width: 1150, height: 800)
        for mark in [CGRect(x: 550, y: 340, width: 90, height: 240), CGRect(x: 830, y: 340, width: 240, height: 220)] {
            let first = CGPoint(x: mark.midX, y: mark.midY - 30)
            let second = CGPoint(x: mark.midX, y: mark.midY + 30)
            let start = DashboardTooltipPlacement.position(pointer: first, avoiding: mark, in: bounds)
            let end = DashboardTooltipPlacement.position(pointer: second, avoiding: mark, in: bounds)
            expectFalse(start == end)
            for point in [start, end] {
                let rect = CGRect(x: point.x - DashboardTooltipPlacement.size.width / 2, y: point.y - DashboardTooltipPlacement.size.height / 2,
                                  width: DashboardTooltipPlacement.size.width, height: DashboardTooltipPlacement.size.height)
                expectFalse(rect.intersects(mark))
                expectTrue(CGRect(origin: .zero, size: bounds).contains(rect))
            }
        }
    }

    @MainActor func testDefaultPeopleAndAttachmentNaming() throws {
        let suite = "Reimbur-default-people-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppPreferences.encodeNames(["张三", "李四"]), forKey: "defaultTravelerNames")
        defaults.set(6000, forKey: "defaultSubsidy")
        defaults.set(2500, forKey: "defaultMeal")
        defaults.set("{报销人}-{费用类型}-{发票号码}", forKey: "invoiceNameFormat")
        defaults.set("{报销人}-行程-{行程单号}", forKey: "itineraryNameFormat")
        let store = ClaimStore(root: temporary)
        let first = store.create(.trip, defaults: ExpenseDefaults.saved(in: defaults))!
        let claim = store.claims.first { $0.id == first }!
        expectEqual(claim.travelerNames, ["张三", "李四"])
        expectEqual(claim.expenses.map(\.claimant), ["张三", "李四"])
        expectEqual(claim.expenses.map(\.unitPrice), [6000, 6000])
        let mealID = store.create(.meal, defaults: ExpenseDefaults.saved(in: defaults))!
        expectEqual(store.claims.first { $0.id == mealID }?.expenses.first?.unitPrice, 2500)
        defaults.set(AppPreferences.encodeNames(["王五"]), forKey: "defaultTravelerNames")
        expectEqual(store.claims.first { $0.id == first }?.travelerNames, ["张三", "李四"])
        let naming = AttachmentNaming.saved(in: defaults)
        let number = "12345678901234567890"
        expectEqual(AttachmentNaming.number(in: "发 票 号 码：\n" + number, role: .invoice), number)
        expectEqual(AttachmentNaming.number(in: "发票号码: 12345678", role: .invoice), "12345678")
        expectEqual(AttachmentNaming.number(in: "订单号：DIDI-123456", role: .itinerary), "DIDI-123456")
        expectEqual(AttachmentNaming.number(in: "", filename: "电子发票" + number, role: .invoice), number)
        expectNil(AttachmentNaming.number(in: "金额 100.00 日期2026-10-24", role: .invoice))
        let expense = Expense(kind: .taxi, claimant: "张三")
        let source = URL(fileURLWithPath: "/tmp/原始文件.pdf")
        expectEqual(naming.filename(source: source, number: number, claim: claim, expense: expense, role: .invoice), "张三-打车-" + number + ".pdf")
        expectEqual(naming.filename(source: source, number: "DIDI123", claim: claim, expense: expense, role: .itinerary), "张三-行程-DIDI123.pdf")
        expectEqual(AttachmentNaming().filename(source: source, number: nil, claim: claim, expense: expense, role: .invoice), "张三原始文件.pdf")
        expectEqual(AppPreferences.caption(String(repeating: "字", count: 20)).count, 14)
        expectFalse(AttachmentNaming.safeStem("../危险:名称/票据").contains("/"))
    }

    @MainActor func testDailyReimbursementsKeepInvoiceTotalsIndependent() throws {
        let source = temporary.appendingPathComponent("发票.pdf")
        try makePDF(at: source, pages: 1, number: "12345678901234567890")
        for kind in [ClaimKind.meal] {
            let root = temporary.appendingPathComponent(kind.id)
            let store = ClaimStore(root: root)
            var claim = Claim.make(kind)
            claim.setTravelerNames(["张三"])
            claim.dates = ["2026-10-23", "2026-10-24"]
            claim.expenses[0].unitPrice = 2500
            let id = claim.expenses[0].id
            claim = try store.importFiles([source], into: claim, expenseID: id)
            expectEqual(claim.total, 5000)
            expectEqual(claim.invoiceTotal, 55300)
            expectEqual(claim.difference, -50300)
            expectEqual(claim.personBreakdowns[0].total(in: claim), 5000)
            expectEqual(claim.expenseGroups[0].total(in: claim), 5000)
            expectNil(claim.expenses[0].totalAmount)
            claim.expenses[0].invoices[0].amount = 10000
            claim.expenses[0].synchronizeInvoiceTotal()
            expectEqual(claim.total, 5000)
            expectEqual(claim.invoiceTotal, 10000)
            claim.dates.insert("2026-10-25")
            expectEqual(claim.total, 7500)
            claim = try store.importFiles([source], into: claim, expenseID: id)
            expectEqual(claim.total, 7500)
            expectEqual(claim.invoiceTotal, 65300)
            claim = store.removeAttachment(claim.expenses[0].invoices[0], from: claim, expenseID: id)!
            expectEqual(claim.total, 7500)
            expectEqual(claim.invoiceTotal, 55300)
            // Records saved by v0.8.0 must recover their daily rate and dates on load.
            claim.expenses[0].totalAmount = 55300
            claim.expenses[0].invoiceTotalLinked = true
            expectEqual(claim.total, 7500)
            try Database(root: root).save(claim)
            let loaded = ClaimStore(root: root).claims[0]
            expectEqual(loaded.total, 7500)
            expectEqual(loaded.invoiceTotal, 55300)
            expectEqual(loaded.invoiceCount, 1)
            expectEqual(loaded.expenses[0].unitPrice, 2500)
            expectEqual(loaded.expenses[0].invoices, claim.expenses[0].invoices)
            expectNil(loaded.expenses[0].totalAmount)
            expectNil(loaded.expenses[0].invoiceTotalLinked)
            let persisted = try Database(root: root).load()[0]
            expectNil(persisted.expenses[0].totalAmount)
            expectNil(persisted.expenses[0].invoiceTotalLinked)
            let summary = ClaimSummary.renderOverview(loaded)
            expectTrue(summary.contains("*总额：75.00=75.00"))
            expectTrue(summary.contains("*发票金额：553.00"))
            expectTrue(loaded.expenses[0].formula(in: loaded).contains("3 天 ×"))
        }
    }

    @MainActor func testInvoiceTotalsRoutesAndDirectHotelPrices() throws {
        expectEqual(AttachmentRecognition.trainRoute(in: "出发站：上海虹桥\n到达站：杭州东"), RailRoute(origin: "上海虹桥", destination: "杭州东"))
        expectEqual(AttachmentRecognition.trainRoute(in: "上海虹桥 → 杭州东"), RailRoute(origin: "上海虹桥", destination: "杭州东"))
        expectEqual(AttachmentRecognition.trainRoute(in: "上海虹桥\nShanghaihongqiao\nG1234\n杭州东\nHangzhoudong"), RailRoute(origin: "上海虹桥", destination: "杭州东"))
        expectNil(AttachmentRecognition.trainRoute(in: "电子发票\n发票号码：12345678\n价税合计¥10.00"))
        let root = temporary.appendingPathComponent("db")
        var old = Claim.make(.trip)
        old.setTravelerNames(["张三"])
        old.dates = ["2026-10-21", "2026-10-22", "2026-10-23"]
        old.expenses = [Expense(kind: .hotel, unitPrice: 32000, quantity: 2)]
        try Database(root: root).save(old)
        let store = ClaimStore(root: root)
        var migrated = store.claims[0]
        expectEqual(migrated.total, 128000)
        expectEqual(migrated.expenses[0].totalAmount, 128000)
        migrated.dates = ["2026-10-24"]
        expectEqual(migrated.total, 128000)
        migrated.expenses[0].setTotalAmount(25000)
        expectEqual(migrated.total, 25000)
        expectTrue(store.save(migrated))
        expectEqual(ClaimStore(root: root).claims[0].total, 25000)
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三"])
        claim.dates = ["2026-10-21", "2026-10-22"]
        claim.expenses = [Expense(kind: .train, unitPrice: 1000, claimant: "张三")]
        let id = claim.expenses[0].id
        let pdf = temporary.appendingPathComponent("车票.pdf")
        try makePDF(at: pdf, pages: 1, number: "12345678901234567890")
        claim = try store.importFiles([pdf, pdf], into: claim, expenseID: id)
        expectEqual(claim.total, 110600)
        expectEqual(claim.invoiceTotal, 110600)
        expectEqual(claim.difference, 0)
        expectEqual(claim.expenseGroups[0].total(in: claim), 110600)
        expectEqual(claim.personBreakdowns[0].total(in: claim), 110600)
        expectEqual(claim.expenses[0].origin, "上海")
        expectEqual(claim.expenses[0].destination, "杭州")
        let removed = claim.expenses[0].invoices[1]
        claim = store.removeAttachment(removed, from: claim, expenseID: id)!
        expectEqual(claim.total, 55300)
        claim.expenses[0].setTotalAmount(60000)
        expectEqual(claim.total, 60000)
        claim.expenses[0].invoices[0].amount = 56000
        claim.expenses[0].synchronizeInvoiceTotal()
        expectEqual(claim.total, 56000)
        let unknown = temporary.appendingPathComponent("无法识别金额.pdf")
        try makePDF(at: unknown, pages: 1, number: "87654321", amount: nil)
        claim.expenses[0].setTotalAmount(70000)
        claim = try store.importFiles([unknown], into: claim, expenseID: id)
        expectEqual(claim.total, 70000)
        claim.addExpense(.hotel, unitPrice: 0)
        let hotel = claim.expenses[1].id
        claim.expenses[1].setTotalAmount(90000)
        claim = try store.importFiles([pdf], into: claim, expenseID: hotel)
        expectEqual(claim.expenses[1].total(in: claim), 55300)
        expectEqual(claim.total, 125300)
        expectTrue(ClaimSummary.renderOverview(claim).contains("住宿总价"))
        claim.dates = []
        expectEqual(claim.expenses[1].total(in: claim), 55300)
        expectTrue(store.save(claim))
        expectEqual(ClaimStore(root: root).claims.first { $0.id == claim.id }?.total, 125300)
        var meal = Claim.make(.meal)
        meal.dates = ["2026-10-21", "2026-10-22"]
        meal.expenses[0].unitPrice = 2000
        meal = try store.importFiles([pdf], into: meal, expenseID: meal.expenses[0].id)
        expectEqual(meal.total, 4000)
        meal.expenses[0].setDailyPrice(3000)
        expectEqual(meal.total, 6000)
        if let path = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: path)
            for kind in [ExpenseKind.train, .hotel] {
                var screen = claim
                screen.expenses = claim.expenses.filter { $0.kind == kind }
                screen.dates = ["2026-10-21", "2026-10-22"]
                try captureView(ClaimEditor(claim: screen).environmentObject(store).textFieldStyle(.roundedBorder).background(Palette.canvas).tint(Palette.accent),
                                width: 1100, height: 1050, to: qa.appendingPathComponent("\(kind == .hotel ? "hotel-total" : "train-route")-editor.png")) { _, host in
                    @MainActor func findScroll(_ view: NSView) -> NSScrollView? {
                        if let scroll = view as? NSScrollView { return scroll }
                        return view.subviews.lazy.compactMap { findScroll($0) }.first
                    }
                    if let scroll = findScroll(host), let document = scroll.documentView {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        pumpNativeEvents()
                    }
                }
            }
            expectEqual(store.claims.first { $0.id == claim.id }?.expenses.first { $0.kind == .hotel }?.invoiceTotalLinked, true)
            meal.expenses[0].synchronizeInvoiceTotal()
            expectTrue(store.save(meal))
            try captureView(ClaimEditor(claim: meal).environmentObject(store).textFieldStyle(.roundedBorder).background(Palette.canvas).tint(Palette.accent),
                            width: 1100, height: 1050, to: qa.appendingPathComponent("meal-invoice-total.png"))
            expectEqual(store.claims.first { $0.id == meal.id }?.total, 6000)
        }
    }

    func testScannedRailTicketRecognizesRouteAndAmount() throws {
        let source = temporary.appendingPathComponent("铁路电子客票.pdf")
        try makePDF(at: source, pages: 1, number: "12345678901234567890")
        let original = PDFDocument(url: source)!
        let image = original.page(at: 0)!.thumbnail(of: NSSize(width: 1684, height: 1190), for: .mediaBox)
        let scan = PDFDocument()
        scan.insert(PDFPage(image: image)!, at: 0)
        let metadata = AttachmentRecognition.read(pdf: scan, source: source, role: .invoice, kind: .train)
        expectEqual(metadata.amount, 55300)
        expectEqual(metadata.route, RailRoute(origin: "上海虹桥", destination: "杭州东"))
    }

    @MainActor func testAttachmentRenamePersistsAndKeepsFilesUsable() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三"])
        claim.expenses = [Expense(kind: .taxi, claimant: "张三")]
        let id = claim.expenses[0].id
        let pdf = temporary.appendingPathComponent("原发票.pdf")
        try makePDF(at: pdf, pages: 1, number: "12345678")
        claim = try store.importFiles([pdf], into: claim, expenseID: id)
        claim = try store.importFiles([pdf], into: claim, expenseID: id, role: .itinerary)
        let old = claim.expenses[0].invoices[0]
        let state = AttachmentNameState(old)
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        let view = AttachmentNameInteractionView(state: state) { stem in
            do {
                claim = try store.renameAttachment(state.attachment, to: stem, in: claim, expenseID: id)
                state.attachment = claim.expenses[0].invoices[0]
            } catch { fail(error.localizedDescription) }
        }
        try captureView(view, width: 500, height: 80, to: qa.appendingPathComponent("rename-invoice.png")) { window, host in
            nativeClick(NSPoint(x: 100, y: 40), in: host, window: window)
            pumpNativeEvents()
            guard let editor = window.firstResponder as? NSTextView else { fail("Click filename must focus name editor"); return }
            editor.selectAll(nil); editor.insertText("临时发票", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertNewline(nil)
            pumpNativeEvents()
            expectEqual(state.attachment.name, "临时发票.pdf")
            nativeClick(NSPoint(x: 100, y: 40), in: host, window: window)
            guard let blurEditor = window.firstResponder as? NSTextView else { fail("Second click must focus name editor"); return }
            blurEditor.selectAll(nil); blurEditor.insertText("打车报销发票", replacementRange: NSRange(location: NSNotFound, length: 0))
            pumpNativeEvents()
            nativeClick(NSPoint(x: 100, y: 5), in: host, window: window)
            expectEqual(state.attachment.name, "打车报销发票.pdf")
            nativeClick(NSPoint(x: 100, y: 40), in: host, window: window)
            guard let cancelEditor = window.firstResponder as? NSTextView else { fail("Click must focus name editor before cancel"); return }
            cancelEditor.selectAll(nil); cancelEditor.insertText("不保存的名称", replacementRange: NSRange(location: NSNotFound, length: 0))
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            window.sendEvent(escape)
            pumpNativeEvents()
            expectEqual(state.attachment.name, "打车报销发票.pdf")
        }
        expectFalse(FileManager.default.fileExists(atPath: store.url(for: old).path))
        claim = try store.renameAttachment(claim.expenses[0].itineraries![0], to: "打车报销发票", in: claim, expenseID: id)
        expectEqual(claim.expenses[0].itineraries?[0].name, "打车报销发票_1.pdf")
        claim = try store.renameAttachment(claim.expenses[0].invoices[0], to: "TAXI", in: claim, expenseID: id)
        claim = try store.renameAttachment(claim.expenses[0].invoices[0], to: "taxi", in: claim, expenseID: id)
        expectEqual(claim.expenses[0].invoices[0].name, "taxi.pdf")
        expectThrowsError(try store.renameAttachment(claim.expenses[0].invoices[0], to: " ", in: claim, expenseID: id))
        let legacy = Attachment(name: "旧附件.pdf", storedName: UUID().uuidString + ".pdf", amount: 1200)
        try FileManager.default.copyItem(at: pdf, to: store.url(for: legacy))
        claim.expenses[0].invoices.append(legacy)
        expectTrue(store.save(claim))
        claim = try store.renameAttachment(legacy, to: "旧附件改名", in: claim, expenseID: id)
        expectFalse(FileManager.default.fileExists(atPath: store.url(for: legacy).path))
        expectEqual(claim.expenses[0].invoices.last?.name, "旧附件改名.pdf")
        expectEqual(claim.expenses[0].invoices.last?.amount, 1200)
        let loaded = ClaimStore(root: store.root).claims[0]
        expectEqual(loaded.expenses, claim.expenses)
        let originals = try Data(contentsOf: pdf)
        for attachment in loaded.attachments {
            expectEqual(try Data(contentsOf: store.url(for: attachment)), originals)
            store.previewAttachment(attachment, in: loaded)
            expectNil(AttachmentPreviewSession(request: store.preview!).errorMessage)
        }
        let archive = temporary.appendingPathComponent("renamed.zip")
        try InvoiceArchiveExporter.export(claim: loaded, attachmentRoot: store.root.appendingPathComponent("Attachments"), to: archive)
        let unpacked = temporary.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        for attachment in loaded.attachments {
            expectEqual(try Data(contentsOf: unpacked.appendingPathComponent(loaded.title).appendingPathComponent(attachment.name)), originals)
        }
    }

    @MainActor func testImportedAttachmentPreviewAndAutomaticAmounts() throws {
        expectEqual(AttachmentRecognition.amount(in: "金额 858.49 税额 51.51\n价税合计（大写）玖佰壹拾圆整\n（小写）\n¥910.00"), 91000)
        expectEqual(AttachmentRecognition.amount(in: "价税合计（大写）叁拾伍圆肆角壹分 ¥35.41\n（小写）\n备注"), 3541)
        expectEqual(AttachmentRecognition.amount(in: "票价（人民币）：￥1,234.50"), 123450)
        expectEqual(AttachmentRecognition.amount(in: "实付金额：88.80元"), 8880)
        expectEqual(AttachmentRecognition.amount(in: "价 税 合 计 ¥0.00"), 0)
        expectNil(AttachmentRecognition.amount(in: "单价 ¥99.00\n数量2\n金额198.00 税额5.94"))
        expectNil(AttachmentRecognition.amount(in: "价税合计 ¥-35.41"))
        expectNil(AttachmentRecognition.amount(in: "价税合计 ¥35.411"))
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三"])
        claim.expenses = [Expense(kind: .taxi, claimant: "张三")]
        let id = claim.expenses[0].id
        let invoice = temporary.appendingPathComponent("原发票.pdf")
        try makePDF(at: invoice, pages: 1, number: "12345678901234567890")
        claim = try store.importFiles([invoice], into: claim, expenseID: id, naming: AttachmentNaming())
        expectEqual(claim.expenses[0].invoices[0].amount, 55300)
        let document = PDFDocument(url: invoice)!
        let image = document.page(at: 0)!.thumbnail(of: NSSize(width: 1684, height: 1190), for: .mediaBox)
        let scanned = PDFDocument()
        scanned.insert(PDFPage(image: image)!, at: 0)
        let scan = temporary.appendingPathComponent("扫描件.pdf")
        expectTrue(scanned.write(to: scan))
        claim = try store.importFiles([scan], into: claim, expenseID: id, naming: AttachmentNaming())
        expectEqual(claim.expenses[0].invoices[1].amount, 55300)
        let itinerary = temporary.appendingPathComponent("没有编号的行程单.pdf")
        try makePDF(at: itinerary, pages: 1)
        claim = try store.importFiles([itinerary], into: claim, expenseID: id, role: .itinerary, naming: AttachmentNaming())
        expectEqual(claim.expenses[0].itineraries?[0].name, "张三12345678901234567890_2.pdf")
        expectEqual(claim.expenses[0].itineraries?[0].amount, 0)
        var ambiguous = claim.expenses[0]
        ambiguous.invoices.append(Attachment(name: "其他发票.pdf", storedName: "other.pdf", number: "99999999"))
        expectEqual(AttachmentNaming().filename(source: itinerary, number: nil, claim: claim, expense: ambiguous, role: .itinerary), "张三没有编号的行程单.pdf")
        let imageFile = temporary.appendingPathComponent("行程图片.png")
        var rect = CGRect(origin: .zero, size: image.size)
        let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageFile)
        let custom = AttachmentNaming(itineraryFormat: "{报销人}-行程-{行程单号}")
        claim = try store.importFiles([imageFile], into: claim, expenseID: id, role: .itinerary, naming: custom)
        expectEqual(claim.expenses[0].itineraries?.last?.name, "张三-行程-12345678901234567890.png")
        // Legacy flat files and new private directories must work in one preview gallery.
        let legacy = Attachment(name: "旧发票.pdf", storedName: "legacy.pdf", amount: 100)
        try FileManager.default.copyItem(at: invoice, to: store.url(for: legacy))
        claim.expenses[0].invoices.append(legacy)
        for attachment in claim.attachments {
            store.previewAttachment(attachment, in: claim)
            guard let request = store.preview else { fail("Missing preview request"); continue }
            expectEqual(request.url, store.url(for: attachment))
            let session = AttachmentPreviewSession(request: request)
            expectNil(session.errorMessage)
            expectTrue(session.image != nil)
            if session.canMoveNext { session.move(1); expectNil(session.errorMessage) }
        }
        claim.expenses[0].invoices[0].amount = 12345
        expectTrue(store.save(claim))
        let restored = ClaimStore(root: store.root).claims[0]
        expectEqual(restored.expenses[0].invoices[0].amount, 12345)
        expectEqual(restored.invoiceCount, 3)
        expectEqual(restored.invoiceTotal, 67745)
        if let path = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: path)
            store.previewAttachment(claim.expenses[0].invoices[0], in: claim)
            try captureView(AttachmentPreview(request: store.preview!), width: 1000, height: 740, to: qa.appendingPathComponent("imported-pdf-preview.png"))
            try captureView(ClaimEditor(claim: claim).environmentObject(store).background(Palette.canvas).tint(Palette.accent), width: 1100, height: 1000, to: qa.appendingPathComponent("export-buttons.png"))
        }
    }

    @MainActor func testUpdatedDefaultsLayout() throws {
        let suite = "Reimbur-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppPreferences.encodeNames(["张三", "李四"]), forKey: "defaultTravelerNames")
        defaults.set(6000, forKey: "defaultSubsidy")
        defaults.set(2500, forKey: "defaultMeal")
        defaults.set(99999, forKey: "defaultHotel")
        defaults.set(99999, forKey: "defaultAllowance")
        let values = ExpenseDefaults.saved(in: defaults)
        expectEqual(values.travelerNames, ["张三", "李四"])
        expectEqual(values.subsidy, 6000)
        expectEqual(values.meal, 2500)
        expectEqual(values.price(for: .hotel), 0)
        expectEqual(values.price(for: .allowance), 0)
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        if let path = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: path)
            try captureView(SettingsView().environmentObject(store).defaultAppStorage(defaults).textFieldStyle(.roundedBorder).background(Palette.canvas).tint(Palette.accent),
                            width: 1050, height: 1200, to: qa.appendingPathComponent("settings-defaults.png"))
            try captureView(WorkspaceView().environmentObject(store).defaultAppStorage(defaults), width: 1440, height: 1000, to: qa.appendingPathComponent("settings-spacing.png"))
        }
    }

    @MainActor func testDuplicateAttachmentNamesReceiveNumberedSuffixes() throws {
        let root = temporary.appendingPathComponent("db")
        let store = ClaimStore(root: root)
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三"])
        claim.expenses = [Expense(kind: .taxi, claimant: "张三"), Expense(kind: .train, claimant: "张三")]
        let taxi = claim.expenses[0].id, train = claim.expenses[1].id
        let source = temporary.appendingPathComponent("原件.pdf")
        try makePDF(at: source, pages: 1, number: "12345678")
        let naming = AttachmentNaming(invoiceFormat: "{报销人}{发票号码}", itineraryFormat: "{报销人}{发票号码}")
        let stem = "张三12345678"
        claim = try store.importFiles([source, source, source], into: claim, expenseID: taxi, naming: naming)
        expectEqual(claim.expenses[0].invoices.map(\.name), [stem + ".pdf", stem + "_1.pdf", stem + "_2.pdf"])
        claim = try store.importFiles([source], into: claim, expenseID: train, naming: naming)
        expectEqual(claim.expenses[1].invoices[0].name, stem + "_3.pdf")
        claim = try store.importFiles([source], into: claim, expenseID: taxi, role: .itinerary, naming: naming)
        expectEqual(claim.expenses[0].itineraries?[0].name, stem + "_4.pdf")
        let reopened = ClaimStore(root: root)
        claim = reopened.claims.first { $0.id == claim.id }!
        claim = try reopened.importFiles([source], into: claim, expenseID: taxi, naming: naming)
        expectEqual(claim.expenses[0].invoices.last?.name, stem + "_5.pdf")
        let originals = try Data(contentsOf: source)
        for attachment in claim.expenses.flatMap(\.attachments) {
            expectEqual(reopened.url(for: attachment).lastPathComponent, attachment.name)
            expectEqual(try Data(contentsOf: reopened.url(for: attachment)), originals)
        }
        // A new upload must also respect a literal name that already contains a suffix.
        var used: Set<String> = ["invoice.pdf", "invoice_1.pdf", "invoice_3.pdf"]
        expectEqual(AttachmentNaming.uniqueFilename("INVOICE.PDF", usedNames: &used), "INVOICE_2.PDF")
        expectEqual(AttachmentNaming.uniqueFilename("invoice.pdf", usedNames: &used), "invoice_4.pdf")
        expectEqual(AttachmentNaming.uniqueFilename("invoice.png", usedNames: &used), "invoice.png")
        // Legacy duplicate display names must get the same suffixes when exporting.
        claim.expenses[1].invoices[0].name = stem + ".pdf"
        let archive = temporary.appendingPathComponent("重复名称.zip")
        try InvoiceArchiveExporter.export(claim: claim, attachmentRoot: root.appendingPathComponent("Attachments"), to: archive)
        let unpacked = temporary.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let folder = unpacked.appendingPathComponent(claim.title)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        expectEqual(Set(files.map(\.lastPathComponent)), Set([".pdf", "_1.pdf", "_2.pdf", "_3.pdf", "_4.pdf", "_5.pdf"].map { stem + $0 }))
        for file in files { expectEqual(try Data(contentsOf: file), originals) }
    }

    @MainActor func testItinerariesAreExcludedAndArchivesRetainOriginals() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三"])
        claim.dates = ["2026-10-23", "2026-10-24"]
        claim.expenses = [Expense(kind: .taxi, unitPrice: 10000, claimant: "张三")]
        let id = claim.expenses[0].id
        let invoice = temporary.appendingPathComponent("发票.pdf")
        try makePDF(at: invoice, pages: 1, number: "12345678901234567890")
        let invoiceDocument = PDFDocument(url: invoice)!
        let rendered = invoiceDocument.page(at: 0)!.thumbnail(of: NSSize(width: 1684, height: 1190), for: .mediaBox)
        let scanned = PDFDocument()
        scanned.insert(PDFPage(image: rendered)!, at: 0)
        expectEqual(AttachmentNaming.number(in: scanned, source: temporary.appendingPathComponent("扫描.pdf"), role: .invoice), "12345678901234567890")
        let itinerary = temporary.appendingPathComponent("行程单.pdf")
        try makePDF(at: itinerary, pages: 2)
        let naming = AttachmentNaming()
        claim = try store.importFiles([invoice, invoice], into: claim, expenseID: id, naming: naming)
        expectEqual(claim.expenses[0].invoices.map(\.name), ["张三12345678901234567890.pdf", "张三12345678901234567890_1.pdf"])
        expectEqual(claim.expenses[0].invoices[0].number, "12345678901234567890")
        expectFalse(claim.expenses[0].invoices[0].storedName == claim.expenses[0].invoices[1].storedName)
        expectEqual(store.url(for: claim.expenses[0].invoices[0]).lastPathComponent, "张三12345678901234567890.pdf")
        claim.expenses[0].invoices[0].amount = 8000
        claim.expenses[0].invoices[1].amount = 1000
        let before = claim
        claim = try store.importFiles([itinerary], into: claim, expenseID: id, role: .itinerary, naming: naming)
        let image = temporary.appendingPathComponent("行程截图.png")
        try makeCover(at: image)
        claim = try store.importFiles([image], into: claim, expenseID: id, role: .itinerary, naming: naming)
        claim.expenses[0].itineraries?[0].amount = 9999999
        expectEqual(claim.total, before.total)
        expectEqual(claim.invoiceCount, before.invoiceCount)
        expectEqual(claim.invoiceTotal, before.invoiceTotal)
        expectEqual(claim.difference, before.difference)
        expectEqual(claim.expenseGroups[0].invoiceCount, 2)
        expectEqual(claim.personBreakdowns[0].invoiceTotal, 9000)
        expectEqual(claim.personBreakdowns[0].invoiceCount, 2)
        expectEqual(claim.attachments.count, 4)
        expectTrue(store.save(claim))
        let loaded = ClaimStore(root: store.root).claims[0]
        expectEqual(loaded.expenses, claim.expenses)
        expectEqual(loaded.travelerNames, claim.travelerNames)
        let legacy = Claim.make(.trip)
        let legacyRoundTrip = try JSONDecoder().decode(Claim.self, from: JSONEncoder().encode(legacy))
        expectNil(legacyRoundTrip.expenses[0].itineraries)
        let archive = temporary.appendingPathComponent("发票汇总.zip")
        try InvoiceArchiveExporter.export(claim: claim, attachmentRoot: store.root.appendingPathComponent("Attachments"), to: archive)
        let unpacked = temporary.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let base = unpacked.appendingPathComponent(claim.title)
        let files = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        expectEqual(files.count, 4)
        for attachment in claim.expenses.flatMap(\.attachments) {
            expectEqual(try Data(contentsOf: base.appendingPathComponent(attachment.name)), try Data(contentsOf: store.url(for: attachment)))
        }
        let document = temporary.appendingPathComponent("行程单打印.docx")
        try WordExporter.export(claims: [claim], attachmentRoot: store.root.appendingPathComponent("Attachments"), to: document)
        let word = temporary.appendingPathComponent("word")
        try run("/usr/bin/ditto", ["-x", "-k", document.path, word.path])
        let xml = try String(contentsOf: word.appendingPathComponent("word/document.xml"), encoding: .utf8)
        for attachment in claim.expenses[0].itineraries ?? [] { expectTrue(xml.contains("行程单 · " + attachment.name)) }
        expectFalse(xml.contains("<w:t"))
        expectEqual(xml.components(separatedBy: "<pic:pic>").count - 1, 5)
        if let path = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try Data(contentsOf: document).write(to: qa.appendingPathComponent("itinerary-print.docx"))
        }
        let retained = claim.expenses[0].invoices[0]
        let removed = claim.expenses[0].itineraries![0]
        claim = store.removeAttachment(removed, from: claim, expenseID: id)!
        expectEqual(claim.invoiceCount, 2)
        expectEqual(claim.expenses[0].itineraries?.count, 1)
        expectFalse(FileManager.default.fileExists(atPath: store.url(for: removed).path))
        expectTrue(FileManager.default.fileExists(atPath: store.url(for: retained).path))
        let originalArchive = try Data(contentsOf: archive)
        try FileManager.default.removeItem(at: store.url(for: retained))
        expectThrowsError(try InvoiceArchiveExporter.export(claim: claim, attachmentRoot: store.root.appendingPathComponent("Attachments"), to: archive))
        expectEqual(try Data(contentsOf: archive), originalArchive)
        expectTrue(store.delete(claim))
        expectFalse(FileManager.default.fileExists(atPath: store.url(for: claim.expenses[0].itineraries![0]).path))
    }

    @MainActor func testUpdatedSettingsAndTaxiScreenshots() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        let qa = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0) } ?? temporary!
        try captureView(WorkspaceView().environmentObject(store).onAppear { store.showSettings = true }, width: 1440, height: 1100,
                        to: qa.appendingPathComponent("settings.png"))
        var claim = Claim.make(.trip)
        claim.setTravelerNames(["张三"])
        claim.expenses = [Expense(kind: .taxi, unitPrice: 6000, claimant: "张三")]
        let pdf = temporary.appendingPathComponent("行程单.pdf")
        try makePDF(at: pdf, pages: 1)
        claim = try store.importFiles([pdf], into: claim, expenseID: claim.expenses[0].id, role: .itinerary, naming: AttachmentNaming())
        try captureView(ClaimEditor(claim: claim).environmentObject(store).background(Palette.canvas).tint(Palette.accent), width: 1150, height: 1400,
                        to: qa.appendingPathComponent("taxi-itinerary.png")) { _, host in
            @MainActor func scrollView(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView($0) }.first
            }
            if let scroll = scrollView(host), let document = scroll.documentView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                pumpNativeEvents()
            } else { fail("Missing expense scroll view") }
        }
    }

    @MainActor func testBatchDeleteAndRenamePreserveOtherRecords() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        let source = temporary.appendingPathComponent("票.pdf")
        try makePDF(at: source, pages: 1)
        var records: [Claim] = []
        for _ in 0..<3 {
            var claim = Claim.make(.meal)
            claim = try store.importFiles([source], into: claim, expenseID: claim.expenses[0].id)
            records.append(claim)
        }
        store.rename(records[0].id, to: "重复名称")
        store.rename(records[2].id, to: "重复名称")
        expectEqual(store.claims.filter { $0.title == "重复名称" }.count, 2)
        expectTrue(store.delete(ids: [records[0].id, records[1].id]))
        expectEqual(store.claims.map(\.id), [records[2].id])
        expectFalse(store.save(records[0]))
        expectEqual(ClaimStore(root: store.root).claims.count, 1)
        for record in records.prefix(2) { expectFalse(FileManager.default.fileExists(atPath: store.url(for: record.attachments[0]).path)) }
        expectTrue(FileManager.default.fileExists(atPath: store.url(for: records[2].attachments[0]).path))
    }

    @MainActor func testNativeNameConfirmationCalendarDragAndMaskDismissal() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        let state = InteractionState()
        let host = NSHostingView(rootView: InteractionView(state: state).frame(width: 638, height: 360).background(.white))
        let window = TestWindow(contentRect: NSRect(x: 100, y: 100, width: 650, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        func pause(_ duration: Double = 0.1) {
            let end = Date().addingTimeInterval(duration)
            while Date() < end {
                if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true), ![NSEvent.EventType.keyDown, .keyUp, .flagsChanged].contains(event.type) { NSApplication.shared.sendEvent(event) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        var sequence = 0
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) {
            let location = host.convert(point, to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: sequence, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApplication.shared.sendEvent(event)
        }
        func click(_ point: NSPoint) {
            sequence += 1
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: host.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: sequence, clickCount: 1, pressure: 0)!
            NSApplication.shared.postEvent(up, atStart: false)
            mouse(.leftMouseDown, point); pause()
        }
        func nameField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap { nameField(in: $0) }.first
        }
        guard let field = nameField(in: host) else { fail("Missing traveler name field"); window.orderOut(nil); return }
        click(host.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field))
        if let editor = window.firstResponder as? NSTextView { editor.insertText("张三", replacementRange: NSRange(location: NSNotFound, length: 0)); pause(); editor.insertNewline(nil) }
        pause()
        expectEqual(state.names, ["张三"])
        if let editor = window.firstResponder as? NSTextView { editor.insertText("李四", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        pause()
        click(NSPoint(x: 15, y: 20))
        expectEqual(state.names, ["张三", "李四"])
        pause(0.6)
        host.layoutSubtreeIfNeeded()
        pause(0.2)
        click(NSPoint(x: 473, y: 129))
        expectTrue(state.dates.isEmpty)
        let windowNumber = window.windowNumber
        sequence += 1
        let dragSequence = sequence
        let points = (1...20).map { host.convert(NSPoint(x: 512 + Double($0) * 3.9, y: 129), to: nil) }
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.35)
            for (index, point) in points.enumerated() {
                let type: NSEvent.EventType = index == 19 ? .leftMouseUp : .leftMouseDragged
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil, eventNumber: dragSequence, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                NSApplication.shared.postEvent(event, atStart: false)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        mouse(.leftMouseDown, NSPoint(x: 512, y: 129)); pause(0.8)
        expectEqual(state.dates, ["2026-10-02", "2026-10-03", "2026-10-04"])
        window.orderOut(nil)
        var closed = false
        let overlay = NSHostingView(rootView: DismissibleOverlay(close: { closed = true }) {
            VStack { Text("预览内容"); Spacer() }
        }.frame(width: 638, height: 360))
        let previewWindow = TestWindow(contentRect: NSRect(x: 100, y: 100, width: 638, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.contentView = overlay
        previewWindow.makeKeyAndOrderFront(nil)
        pause()
        func overlayClick(_ point: NSPoint) {
            let location = overlay.convert(point, to: nil)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: previewWindow.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
            NSApplication.shared.postEvent(up, atStart: false)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: previewWindow.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
            NSApplication.shared.sendEvent(down); pause()
        }
        overlayClick(NSPoint(x: 319, y: 180))
        expectFalse(closed)
        overlayClick(NSPoint(x: 15, y: 180))
        expectTrue(closed)
        previewWindow.orderOut(nil)
    }

    @MainActor func testNativeExpenseCardDragReorder() {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        let state = TabInteractionState()
        let host = NSHostingView(rootView: TabInteractionView(state: state).frame(width: 720, height: 160).background(.white))
        let window = TestWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        func pause(_ duration: Double) {
            let end = Date().addingTimeInterval(duration)
            while Date() < end {
                if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true), ![NSEvent.EventType.keyDown, .keyUp, .flagsChanged].contains(event.type) { NSApplication.shared.sendEvent(event) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        pause(0.5)
        if let directory = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("tab-harness.png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])!.write(to: url)
        }
        let windowNumber = window.windowNumber
        var sequence = 8
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + (type == .leftMouseUp ? 0.01 : 0), windowNumber: windowNumber, context: nil, eventNumber: sequence, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApplication.shared.postEvent(event(.leftMouseUp, NSPoint(x: 260, y: 70)), atStart: false)
        NSApplication.shared.sendEvent(event(.leftMouseDown, NSPoint(x: 260, y: 70)))
        pause(0.15)
        expectEqual(state.selection, .train)
        func drag(from start: CGFloat, to end: CGFloat) {
            sequence += 1
            let dragSequence = sequence
            let points = (1...30).map { host.convert(NSPoint(x: start + (end - start) * CGFloat($0) / 30, y: 70), to: nil) }
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.05)
                for (index, point) in points.enumerated() {
                    let type: NSEvent.EventType = index == 29 ? .leftMouseUp : .leftMouseDragged
                    let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil, eventNumber: dragSequence, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                    NSApplication.shared.postEvent(e, atStart: false)
                    Thread.sleep(forTimeInterval: 0.015)
                }
            }
            NSApplication.shared.sendEvent(event(.leftMouseDown, NSPoint(x: start, y: 70)))
            pause(1.4)
            host.layoutSubtreeIfNeeded()
            pause(0.4)
        }
        drag(from: 98, to: 426)
        expectEqual(state.claim.expenseGroups.map(\.kind), [.train, .taxi, .subsidy])
        expectEqual(state.selection, .subsidy)
        drag(from: 426, to: 98)
        expectEqual(state.claim.expenseGroups.map(\.kind), [.subsidy, .train, .taxi])
        window.orderOut(nil)
    }

    @MainActor func testNativeRecordsCollapseAndSettingsNavigation() throws {
        let suite = "Reimbur-navigation-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("records", forKey: "startupPage")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClaimStore(root: temporary)
        expectTrue(store.save(sampleClaim()))
        let view = WorkspaceView().environmentObject(store).defaultAppStorage(defaults).preferredColorScheme(.light).tint(Palette.accent)
        let imageURL = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("settings-min-window.png") } ?? temporary.appendingPathComponent("settings.png")
        try captureView(view, width: 1180, height: 760, to: imageURL) { window, host in
            var sequence = 11
            @MainActor func click(_ point: NSPoint) {
                sequence += 1
                let location = host.convert(point, to: nil)
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: sequence, clickCount: 1, pressure: 0)!
                NSApplication.shared.postEvent(up, atStart: false)
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: sequence, clickCount: 1, pressure: 1)!
                NSApplication.shared.sendEvent(down)
                let end = Date().addingTimeInterval(0.35)
                while Date() < end {
                    if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true), ![NSEvent.EventType.keyDown, .keyUp, .flagsChanged].contains(event.type) { NSApplication.shared.sendEvent(event) }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                }
            }
            click(NSPoint(x: 1152, y: 19))
            expectTrue(defaults.bool(forKey: "recordsCollapsed"))
            click(NSPoint(x: 1152, y: 19))
            expectFalse(defaults.bool(forKey: "recordsCollapsed"))
            click(NSPoint(x: 80, y: 666))
            expectTrue(store.showSettings)
        }
    }

    private func sampleClaim() -> Claim {
        var claim = Claim.make(.trip)
        claim.title = "杭州项目出差"
        claim.setTravelerNames(["张三", "李四", "王五"])
        claim.dates = ["2026-10-21", "2026-10-22", "2026-10-23"]
        claim.note = "项目现场沟通，同行人员：张三、李四、王五"
        claim.expenses = [Expense(kind: .subsidy, unitPrice: 10000),
                          Expense(kind: .train, unitPrice: 55300, origin: "上海虹桥", destination: "杭州东"),
                          Expense(kind: .hotel, unitPrice: 32000, quantity: 2, dates: ["2026-10-21", "2026-10-22"])]
        return claim.withPeopleAssigned
    }

    private func multiPersonClaim() -> Claim {
        var claim = Claim.make(.trip)
        claim.title = "襄阳出差"
        claim.dates = ["2026-08-12", "2026-08-13"]
        claim.expenses[0].unitPrice = 6000
        claim.setTravelerNames(["蔡建坤", "孙毅强"])
        func expense(_ kind: ExpenseKind, _ cents: Int64, _ count: Int, _ name: String) -> Expense {
            let invoices = (0..<count).map { index in Attachment(name: "\(kind.rawValue)\(index + 1).pdf", storedName: UUID().uuidString + ".pdf", amount: cents / Int64(count) + (index == 0 ? cents % Int64(count) : 0)) }
            return Expense(kind: kind, unitPrice: cents, origin: kind == .train ? "襄阳" : "杭州", destination: kind == .train ? "杭州" : "襄阳", invoices: invoices, claimant: name)
        }
        claim.expenses += [expense(.flight, 91000, 1, "蔡建坤"), expense(.flight, 91000, 1, "孙毅强"),
                           expense(.train, 55800, 4, "蔡建坤"), expense(.train, 40200, 2, "孙毅强"),
                           expense(.taxi, 25105, 8, "蔡建坤"), expense(.taxi, 17107, 3, "孙毅强"),
                           expense(.hotel, 19000, 1, "蔡建坤")]
        return claim
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReimburError("命令执行失败：\(executable)") }
    }

    private func makePDF(at url: URL, pages: Int, number: String? = nil, amount: String? = "553.00") throws {
        var bounds = CGRect(x: 0, y: 0, width: 842, height: 595)
        let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor.white); context.fill(bounds)
            context.setStrokeColor(CGColor(gray: 0.45, alpha: 1)); context.setLineWidth(1)
            context.stroke(CGRect(x: 40, y: 50, width: 762, height: 495))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black]
            if let number { "发票号码：\(number)".draw(at: NSPoint(x: 80, y: 430), withAttributes: style) }
            "电子发票 测试样本".draw(at: NSPoint(x: 280, y: 470), withAttributes: style)
            "上海虹桥 → 杭州东".draw(at: NSPoint(x: 80, y: 350), withAttributes: style)
            if let amount { "价税合计 ¥\(amount)    第 \(page) 页".draw(at: NSPoint(x: 80, y: 200), withAttributes: style) }
            "仅用于软件导出功能测试".draw(at: NSPoint(x: 80, y: 90), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func makeCover(at url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1190, pixelsHigh: 1684,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1190, height: 1684).fill()
        "费用报销单".draw(at: NSPoint(x: 400, y: 1480), withAttributes: [.font: NSFont.systemFont(ofSize: 52), .foregroundColor: NSColor.black])
        for (line, text) in ["报销项目：杭州项目出差", "报销人：张三", "报销金额：¥2,733.00", "附件：火车发票 1 份，共 2 页", "审批签字：________________", "软件测试样本"].enumerated() {
            text.draw(at: NSPoint(x: 130, y: 1250 - line * 145), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    private func unzip(_ url: URL, entry: String) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // unzip treats [] as patterns; escaping them keeps Content_Types literal.
        task.arguments = ["-p", url.path, entry.replacingOccurrences(of: "[", with: "[[]")]
        let pipe = Pipe(); task.standardOutput = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ReimburError("无法读取测试导出包 \(entry)") }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor private func captureUI(store: ClaimStore, to url: URL) throws {
        let suite = "Reimbur-qa-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = WorkspaceView().environmentObject(store).defaultAppStorage(defaults).frame(width: 1440, height: 1060).preferredColorScheme(.light).tint(Palette.accent)
        try captureView(view, width: 1440, height: 1060, to: url)
        try captureView(view, width: 1440, height: 1060, to: url.deletingLastPathComponent().appendingPathComponent("record-list.png")) { window, hosting in
            let location = hosting.convert(NSPoint(x: 80, y: 238), to: nil)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: 1, pressure: 0)!
            NSApplication.shared.postEvent(up, atStart: false)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: 1, pressure: 1)!
            NSApplication.shared.sendEvent(down)
            let end = Date().addingTimeInterval(0.3)
            while Date() < end {
                if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true), ![NSEvent.EventType.keyDown, .keyUp, .flagsChanged].contains(event.type) { NSApplication.shared.sendEvent(event) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
        }
        defaults.set("records", forKey: "startupPage")
        defaults.set(true, forKey: "recordsCollapsed")
        try captureView(view, width: 1440, height: 1060, to: url.deletingLastPathComponent().appendingPathComponent("record-list-collapsed.png"))
    }

    @MainActor private func captureView<Content: View>(_ view: Content, width: CGFloat, height: CGFloat, to url: URL, interact: (@MainActor (NSWindow, NSHostingView<Content>) -> Void)? = nil) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        let readyAt = Date().addingTimeInterval(2)
        while Date() < readyAt {
            if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true), ![NSEvent.EventType.keyDown, .keyUp, .flagsChanged].contains(event.type) {
                NSApplication.shared.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        interact?(window, hosting)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
    }

    private func hasVisibleInk(_ image: NSImage) -> Bool {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var darkSamples = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 15) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 15) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9,
                   min(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 { darkSamples += 1 }
            }
        }
        return darkSamples > 30
    }
}


private var failures = 0
@MainActor private func pumpNativeEvents(_ duration: Double = 0.25) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end {
        if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true), ![NSEvent.EventType.keyDown, .keyUp, .flagsChanged].contains(event.type) { NSApplication.shared.sendEvent(event) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
}
@MainActor private func verificationViews<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { verificationViews($0, type) }
}
@MainActor private func verificationMovePointer(_ point: NSPoint, in host: NSView, window: NSWindow) {
    window.acceptsMouseMovedEvents = true
    let screen = window.convertPoint(toScreen: host.convert(point, to: nil))
    let global = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y)
    CGWarpMouseCursorPosition(global)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: global, mouseButton: .left)?.post(tap: .cghidEventTap)
    let moved = NSEvent.mouseEvent(with: .mouseMoved, location: host.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    NSApplication.shared.postEvent(moved, atStart: false)
    pumpNativeEvents(0.25)
}
private var nativeEventNumber = 1000
private func nativeFilePreviewPoint(_ name: String, columnStart: CGFloat, columnWidth: CGFloat, y: CGFloat) -> NSPoint {
    let textWidth = min((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width, columnWidth - 49)
    return NSPoint(x: columnStart + columnWidth / 2 - (29 + textWidth) / 2 + 11, y: y)
}
@MainActor private func nativeClick(_ point: NSPoint, in view: NSView, window: NSWindow, count: Int = 1) {
    nativeEventNumber += 1
    let location = view.convert(point, to: nil)
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: nativeEventNumber, clickCount: count, pressure: 0)!
    NSApplication.shared.postEvent(up, atStart: false)
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: nativeEventNumber, clickCount: count, pressure: 1)!
    NSApplication.shared.sendEvent(down)
    pumpNativeEvents()
}
@MainActor private func nativeDrag(from start: NSPoint, to end: NSPoint, in view: NSView, window: NSWindow) {
    nativeEventNumber += 1
    let number = nativeEventNumber, windowNumber = window.windowNumber
    let points = (1...20).map { step in view.convert(NSPoint(x: start.x + (end.x - start.x) * CGFloat(step) / 20, y: start.y + (end.y - start.y) * CGFloat(step) / 20), to: nil) }
    DispatchQueue.global().async {
        Thread.sleep(forTimeInterval: 0.05)
        for (index, point) in points.enumerated() {
            let type: NSEvent.EventType = index == points.count - 1 ? .leftMouseUp : .leftMouseDragged
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApplication.shared.postEvent(event, atStart: false)
            Thread.sleep(forTimeInterval: 0.015)
        }
    }
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(start, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)!
    NSApplication.shared.sendEvent(down)
    pumpNativeEvents(0.9)
}
private func fail(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line): \(text)")
}
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a != b { fail("Expected \(a) == \(b)", file: file, line: line) }
}
private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fail("Expected true", file: file, line: line) }
}
private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value { fail("Expected false", file: file, line: line) }
}
private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { fail("Expected nil", file: file, line: line) }
}
private func expectLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if !(a < b) { fail("Expected ascending order", file: file, line: line) }
}
private func expectThrowsError<T>(_ action: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try action(); fail("Expected error", file: file, line: line) } catch {}
}
private func expectNoThrow<T>(_ action: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try action() } catch { fail(error.localizedDescription, file: file, line: line) }
}

@main struct Verification {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let checks = ReimburChecks()
        let tests: [(String, () throws -> Void)] = [
            ("Manual route text is preserved", checks.testManualRouteTextIsPreserved),
            ("Zoomed previews stay inside viewport", checks.testZoomedPreviewsStayInsideViewport),
            ("Rail cities in lists forms and imports", checks.testRailCitiesInListsFormsAndImports),
            ("Global previews and close buttons", checks.testGlobalPreviewsAndCloseButtons),
            ("Selectable trip form zoom pan and copy", checks.testSelectableTripFormZoomPanAndCopy),
            ("Native invoice hover follows and dismisses", checks.testNativeInvoiceHoverPreviewFollowsAndDismisses),
            ("Rail arrival date defaults and overrides", checks.testRailArrivalDateDefaultsAndOverrides),
            ("Rail times defaults and SQLite compatibility", checks.testRailTimesDefaultsAndPersistence),
            ("Trip form reconciliation and rendering", checks.testTripFormReconciliationAndRendering),
            ("Trip form native editor and time selection", checks.testTripFormNativeEditorAndTimeSelection),
            ("Hover sorting centered cells and external scrollbar", checks.testHoverSortingCenteredCellsAndOverlayScrollbar),
            ("Centered tables adjacent resizing column sorting", checks.testCenteredTablesAdjacentResizeAndSorting),
            ("Table row copies replacement and itinerary capacity", checks.testTableCopyReplacementAndItineraryCapacity),
            ("Trip mixed batch import and rollback", checks.testTripMixedBatchImportAndRollback),
            ("Trip list native editing and screenshots", checks.testTripListNativeEditingAndScreenshots),
            ("Taxi itinerary column and preview", checks.testTaxiAttachmentDisclosure),
            ("Inline ledger files and subsidy columns", checks.testInlineLedgerFilesAndSubsidyColumns),
            ("Undated allowance migration and independent amount", checks.testUndatedAllowanceMigrationAndIndependentAmount),
            ("Undated allowance editor and meal info layout", checks.testUndatedAllowanceEditorAndMealInfoLayout),
            ("Compact meal info and menu navigation", checks.testCompactMealInfoAndMenuNavigation),
            ("Ledger attachment layout and calendar editing", checks.testLedgerAttachmentLayoutAndCalendarEditing),
            ("Invoice ledger legacy migration preserves amounts and attachments", checks.testInvoiceLedgerPreservesLegacyAmountsAndAttachments),
            ("Invoice ledger batch recognition editing and deletion", checks.testInvoiceLedgerBatchRecognitionEditingAndDeletion),
            ("Invoice ledger XLSX and print exports", checks.testInvoiceLedgerXLSXAndPrintExports),
            ("Trip invoice ledger and XLSX export", checks.testTripInvoiceLedgerAndXLSXExport),
            ("Invoice ledger native editing and status chart", checks.testInvoiceLedgerNativeEditingAndStatusChart),
            ("Claim status legacy decoding and SQLite persistence", checks.testClaimStatusLegacyAndSQLitePersistence),
            ("Claim status filtering statistics and record metadata", checks.testClaimStatusFilteringStatisticsAndMetadata),
            ("Claim status native editor synchronization and screenshots", checks.testClaimStatusNativeEditorAndScreenshots),
            ("Daily reimbursements keep invoice totals independent", checks.testDailyReimbursementsKeepInvoiceTotalsIndependent),
            ("Scanned rail ticket recognizes route and amount", checks.testScannedRailTicketRecognizesRouteAndAmount),
            ("Invoice totals, rail routes and direct hotel prices", checks.testInvoiceTotalsRoutesAndDirectHotelPrices),
            ("Attachment renaming persists and files remain usable", checks.testAttachmentRenamePersistsAndKeepsFilesUsable),
            ("Imported attachments preview and automatic amounts", checks.testImportedAttachmentPreviewAndAutomaticAmounts),
            ("Updated defaults layout", checks.testUpdatedDefaultsLayout),
            ("Different personal dates use longest duration and colored statistics", checks.testDifferentPersonalDatesUseLongestDuration),
            ("Gallery navigation, copy, download and interactive canvas", checks.testGalleryNavigationCopyDownloadAndCanvas),
            ("Native calendar cell corners and sweep", checks.testCalendarCellCornersAndSweep),
            ("Traveler rename retains expenses and persists", checks.testTravelerRenamePreservesExpenses),
            ("Native traveler double-click rename", checks.testNativeTravelerDoubleClickRename),
            ("Dashboard sector hover hit testing", checks.testDashboardSectorHoverHitTesting),
            ("Native dashboard hover", checks.testNativeDashboardHover),
            ("Tooltip avoids selected marks and follows cursor", checks.testTooltipAvoidsMarksAndFollowsCursor),
            ("Default people and configurable attachment naming", checks.testDefaultPeopleAndAttachmentNaming),
            ("Duplicate attachment names receive numbered suffixes", checks.testDuplicateAttachmentNamesReceiveNumberedSuffixes),
            ("Itineraries excluded from totals and complete archives", checks.testItinerariesAreExcludedAndArchivesRetainOriginals),
            ("Updated settings and taxi screenshots", checks.testUpdatedSettingsAndTaxiScreenshots),
            ("Two-day hotel means one night with independent stay override", checks.testTwoDayHotelUsesOneNightAndExplicitStayDatesOverride),
            ("Named expenses and per-person subsidies reconcile", checks.testNamedExpensesAndSubsidiesReconcileWithoutDoubleCounting),
            ("Legacy people migration retains invoices and stable row IDs", checks.testLegacyPeopleMigrationPreservesInvoicesAndStableIDs),
            ("Personal summary matches reference with consistent totals", checks.testPersonalSummaryMatchesReferenceAndSurvivesSQLite),
            ("Native expense cards drag and reorder both directions", checks.testNativeExpenseCardDragReorder),
            ("Native record list collapse, expand and settings navigation", checks.testNativeRecordsCollapseAndSettingsNavigation),
            ("Custom expense order persists and legacy records decode", checks.testExpenseOrderPersistsAndLegacyRecordsKeepDefaultOrder),
            ("Default prices apply only to new expenses", checks.testDefaultPricesOnlyApplyToNewExpenses),
            ("Native name confirmation, calendar dragging and mask dismissal", checks.testNativeNameConfirmationCalendarDragAndMaskDismissal),
            ("Native personal preview copies the selected person only", checks.testNativePersonalPreviewCopiesOnlySelectedPerson),
            ("Traveler tags and legacy compatibility", checks.testTravelerTagsAndLegacyDecoding),
            ("Period filtering and copyable grouped summary", checks.testPeriodFilterAndTextSummary),
            ("Calendar sweep selects and erases without repeated toggles", checks.testCalendarSweepIsIdempotentAndSupportsErasing),
            ("Batch delete and duplicate rename persistence", checks.testBatchDeleteAndRenamePreserveOtherRecords),
            ("Decimal money validation", checks.testMoneyUsesCentsAndRejectsInvalidAmounts),
            ("Trip and independent hotel dates", checks.testTripAndIndependentHotelDates),
            ("Meal allowance and negative difference", checks.testMealAndAllowanceIncludingNegativeDifference),
            ("SQLite round trip update delete", checks.testSQLiteRoundTripUpdateAndDelete),
            ("Calendar leap day and year boundary", checks.testCalendarRoundTripAcrossLeapDay),
            ("Date titles and duplicate names survive SQLite", checks.testDefaultDateTitleAllowsDuplicateNames),
            ("Grouped expense totals retain separate routes", checks.testExpenseGroupsAggregateWithoutMergingEntries),
            ("Invoice deletion persists and preserves other files", checks.testInvoiceDeletionPersistsAndPreservesOtherAttachments),
            ("Subsidy skips new invoices and preserves legacy files", checks.testSubsidyRejectsNewInvoicesAndPreservesLegacyAttachments),
            ("Native PDF and image preview", checks.testNativePreviewLoadsPagesAndImages),
            ("Attachment copy batch rollback restart cleanup", checks.testImportCopiesFilesAndRollsBackInvalidBatch),
            ("Attachment-only print layout cropping and rail duplicates", checks.testAttachmentOnlyPrintLayout),
            ("Export failure preserves existing file", checks.testExportFailurePreservesExistingFile)
        ]
        let selectedTests = tests.filter { test in
            ProcessInfo.processInfo.environment["REIMBUR_CHECK_FILTER"].map { filters in
                filters.split(separator: "|").contains { test.0.localizedCaseInsensitiveContains(String($0)) }
            } ?? true
        }
        for (name, test) in selectedTests {
            let before = failures
            do { try checks.setUpWithError(); try test(); try checks.tearDownWithError() }
            catch { fail("\(name): \(error.localizedDescription)"); try? checks.tearDownWithError() }
            print("\(failures == before ? "PASS" : "FAIL") \(name)")
            fflush(stdout)
        }
        print("\(selectedTests.count) checks completed; \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
