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

final class ReimburChecks {
    private var temporary: URL!
    func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Reimbur-tests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

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
            expectTrue(personal.contains("出差人：\(person.name)"))
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
        expectEqual(Claim.make(.allowance, date: date).title, "补助报销20261023")
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
        expectEqual(prices.price(for: .hotel), 32000)
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
            let points = (1...20).map { host.convert(NSPoint(x: 181 + CGFloat($0) * 4, y: 71), to: nil) }
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.35)
                for (index, point) in points.enumerated() {
                    let type: NSEvent.EventType = index == 19 ? .leftMouseUp : .leftMouseDragged
                    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: 700, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                    NSApplication.shared.postEvent(event, atStart: false)
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: host.convert(NSPoint(x: 181, y: 71), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: 700, clickCount: 1, pressure: 1)!
            NSApplication.shared.sendEvent(down)
            pumpNativeEvents(0.9)
            expectEqual(state.dates, ["2026-10-02", "2026-10-03", "2026-10-04"])
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

    @MainActor func testWordContainsSummaryCoverAndPackedPDFPages() throws {
        let store = ClaimStore(root: temporary.appendingPathComponent("db"))
        var claim = sampleClaim()
        expectTrue(store.save(claim))
        let pdf = temporary.appendingPathComponent("火车发票.pdf")
        try makePDF(at: pdf, pages: 2)
        let trainIndex = claim.expenses.firstIndex { $0.kind == .train }!
        claim = try store.importFiles([pdf], into: claim, expenseID: claim.expenses[trainIndex].id)
        claim.expenses[trainIndex].invoices[0].amount = 55300
        let cover = temporary.appendingPathComponent("报销单.png")
        try makeCover(at: cover)
        claim = try store.importFiles([cover], into: claim, expenseID: nil)
        let output = temporary.appendingPathComponent("汇总.docx")
        try WordExporter.export(claims: [claim], attachmentRoot: store.root.appendingPathComponent("Attachments"), to: output)
        let document = try unzip(output, entry: "word/document.xml")
        expectNoThrow(try XMLDocument(xmlString: document))
        expectTrue(document.contains("报销单"))
        expectTrue(document.contains("第 1/2 页"))
        expectTrue(document.contains("第 2/2 页"))
        expectEqual(document.components(separatedBy: "<pic:pic>").count - 1, 3)
        expectLessThan(document.range(of: "报销总额")!.lowerBound, document.range(of: "报销单")!.lowerBound)
        expectLessThan(document.range(of: "报销单")!.lowerBound, document.range(of: "第 1/2 页")!.lowerBound)
        expectEqual(document.components(separatedBy: "w:type=\"page\"").count - 1, 2)
        let single = temporary.appendingPathComponent("单张打印.docx")
        try WordExporter.export(claims: [claim], attachmentRoot: store.root.appendingPathComponent("Attachments"), to: single, packLandscapeInvoices: false)
        let singleDocument = try unzip(single, entry: "word/document.xml")
        expectEqual(singleDocument.components(separatedBy: "w:type=\"page\"").count - 1, 3)
        expectEqual(singleDocument.components(separatedBy: "<pic:pic>").count - 1, 3)
        for entry in ["[Content_Types].xml", "_rels/.rels", "word/styles.xml", "word/_rels/document.xml.rels"] {
            expectNoThrow(try XMLDocument(xmlString: unzip(output, entry: entry)))
        }
        if let directory = ProcessInfo.processInfo.environment["REIMBUR_QA_DIR"] {
            let qa = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: output, to: qa.appendingPathComponent("export-test.docx"))
            try captureUI(store: store, to: qa.appendingPathComponent("app-preview.png"))
            try captureView(SettingsView().environmentObject(store).background(Palette.canvas).preferredColorScheme(.light).tint(Palette.accent), width: 1230, height: 1060, to: qa.appendingPathComponent("settings.png"))
            try captureView(ClaimTextPreview(claim: claim, close: {}), width: 900, height: 740, to: qa.appendingPathComponent("text-preview.png"))
            try captureView(WorkspaceView().environmentObject(store).overlay {
                DismissibleOverlay(close: {}) { AttachmentPreview(request: PreviewRequest(attachment: claim.covers[0], url: store.url(for: claim.covers[0])), close: {}) }
            }.preferredColorScheme(.light), width: 1440, height: 1060, to: qa.appendingPathComponent("masked-preview.png"))
            var grouped = claim
            grouped.expenses.removeAll { $0.kind == .subsidy || $0.kind == .hotel }
            grouped.expenses += [Expense(kind: .train, unitPrice: 40300, origin: "杭州东", destination: "上海虹桥"),
                                 Expense(kind: .taxi, unitPrice: 3800), Expense(kind: .taxi, unitPrice: 5600)]
            try captureView(ClaimEditor(claim: grouped).environmentObject(store).frame(width: 960, height: 1200).background(Palette.canvas).preferredColorScheme(.light).tint(Palette.accent), width: 960, height: 1200, to: qa.appendingPathComponent("grouped-expenses.png"))
            var sixRows = claim
            sixRows.dates = ["2026-11-01", "2026-11-30"]
            try captureView(ClaimEditor(claim: sixRows).environmentObject(store).background(Palette.canvas).preferredColorScheme(.light).tint(Palette.accent), width: 689, height: 1000, to: qa.appendingPathComponent("six-row-calendar-min-width.png"))
            let multi = multiPersonClaim()
            try captureView(ClaimEditor(claim: multi).environmentObject(store).background(Palette.canvas).preferredColorScheme(.light).tint(Palette.accent), width: 960, height: 1540, to: qa.appendingPathComponent("people-editor.png"))
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
        var selection: Set<String> = ["2026-10-01"]
        var paint = CalendarPaintSelection()
        paint.visit("2026-10-02", selection: &selection)
        paint.visit("2026-10-03", selection: &selection)
        paint.visit("2026-10-02", selection: &selection)
        expectEqual(selection, ["2026-10-01", "2026-10-02", "2026-10-03"])
        paint = CalendarPaintSelection()
        paint.visit("2026-10-02", selection: &selection)
        paint.visit("2026-10-03", selection: &selection)
        paint.visit("2026-10-02", selection: &selection)
        expectEqual(selection, ["2026-10-01"])
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
            click(NSPoint(x: 80, y: 720))
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

    private func makePDF(at url: URL, pages: Int) throws {
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
            "电子发票 测试样本".draw(at: NSPoint(x: 280, y: 470), withAttributes: style)
            "上海虹桥 → 杭州东".draw(at: NSPoint(x: 80, y: 350), withAttributes: style)
            "价税合计 ¥553.00    第 \(page) 页".draw(at: NSPoint(x: 80, y: 200), withAttributes: style)
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
private var nativeEventNumber = 1000
@MainActor private func nativeClick(_ point: NSPoint, in view: NSView, window: NSWindow, count: Int = 1) {
    nativeEventNumber += 1
    let location = view.convert(point, to: nil)
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: nativeEventNumber, clickCount: count, pressure: 0)!
    NSApplication.shared.postEvent(up, atStart: false)
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: nativeEventNumber, clickCount: count, pressure: 1)!
    NSApplication.shared.sendEvent(down)
    pumpNativeEvents()
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
            ("Different personal dates use longest duration and colored statistics", checks.testDifferentPersonalDatesUseLongestDuration),
            ("Gallery navigation, copy, download and interactive canvas", checks.testGalleryNavigationCopyDownloadAndCanvas),
            ("Native calendar cell corners and sweep", checks.testCalendarCellCornersAndSweep),
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
            ("Word summary cover order and two invoices per page", checks.testWordContainsSummaryCoverAndPackedPDFPages),
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
