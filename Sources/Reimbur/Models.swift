import Foundation

enum ClaimKind: String, Codable, CaseIterable, Identifiable {
    case trip = "出差", meal = "餐补", allowance = "补助"
    var id: String { rawValue }
    var icon: String {
        switch self { case .trip: return "suitcase.rolling"; case .meal: return "fork.knife"; case .allowance: return "banknote" }
    }
    var categories: [ExpenseKind] {
        switch self {
        case .trip: return [.subsidy, .train, .flight, .taxi, .hotel]
        case .meal: return [.meal]
        case .allowance: return [.allowance]
        }
    }
}

enum ExpenseKind: String, Codable, CaseIterable, Identifiable {
    case subsidy = "出差补助", train = "火车", flight = "飞机", taxi = "打车", hotel = "住宿", meal = "餐补", allowance = "补助"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .subsidy, .allowance: return "banknote"
        case .train: return "tram.fill"
        case .flight: return "airplane"
        case .taxi: return "car.fill"
        case .hotel: return "bed.double.fill"
        case .meal: return "fork.knife"
        }
    }
    var isTransport: Bool { [.train, .flight, .taxi].contains(self) }
    var hasRoute: Bool { self == .train || self == .flight }
    var acceptsInvoices: Bool { self != .subsidy }
}

enum Money {
    // Money is persisted as integer cents. Decimal avoids binary floating point rounding.
    static let maximumCents: Int64 = 100_000_000_000
    static func parse(_ text: String) -> Int64? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^\d{1,9}(\.\d{0,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value >= 0, value * 100 <= Decimal(maximumCents) else { return nil }
        return NSDecimalNumber(decimal: value * 100).int64Value
    }
    static func input(_ cents: Int64) -> String { String(format: "%.2f", Double(cents) / 100) }
    static func format(_ cents: Int64) -> String {
        let number = NumberFormatter()
        number.numberStyle = .currency
        number.locale = Locale(identifier: "zh_CN")
        number.currencySymbol = "¥"
        return number.string(from: NSNumber(value: Double(cents) / 100)) ?? "¥0.00"
    }
}

enum DayKey {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 2
        return c
    }
    static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

struct Attachment: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var storedName: String
    var amount: Int64 = 0
    var pageCount: Int = 1
    var number: String?
}

struct Expense: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ExpenseKind
    var unitPrice: Int64 = 0
    var quantity: Int = 1
    var origin = ""
    var destination = ""
    var note = ""
    // nil uses the claim calendar; a non-nil set selects this expense's own dates.
    var dates: Set<String>?
    var invoices: [Attachment] = []
    // Optional for compatibility with records saved before itinerary support.
    var itineraries: [Attachment]?
    var attachments: [Attachment] { invoices + (itineraries ?? []) }
    var claimant: String?
    // Rows split from the same group retain their relationship when names are added/removed.
    var subsidyGroupID: UUID?
    // Optional fields keep records from earlier versions readable.
    var totalAmount: Int64?
    var invoiceTotalLinked: Bool?
    var synchronizesInvoiceTotal: Bool { kind.isTransport || kind == .hotel }

    mutating func setTotalAmount(_ amount: Int64) {
        totalAmount = amount
        invoiceTotalLinked = false
        if kind.isTransport { unitPrice = amount }
    }
    mutating func synchronizeInvoiceTotal() {
        guard synchronizesInvoiceTotal else {
            totalAmount = nil
            invoiceTotalLinked = nil
            return
        }
        totalAmount = invoiceTotal
        invoiceTotalLinked = true
        if kind.isTransport { unitPrice = invoiceTotal }
    }
    mutating func setDailyPrice(_ amount: Int64) {
        unitPrice = amount
        totalAmount = nil
        invoiceTotalLinked = false
    }

    func days(in claim: Claim) -> Int {
        if kind == .hotel, dates == nil { return max(0, claim.dates.count - 1) }
        return (dates ?? claim.dates).count
    }
    func defaultStayDates(in claim: Claim) -> Set<String> { Set(claim.dates.sorted().dropLast()) }
    func total(in claim: Claim) -> Int64 {
        if synchronizesInvoiceTotal, let totalAmount { return totalAmount }
        if kind.isTransport { return unitPrice }
        let units = kind == .subsidy ? (claimant == nil ? claim.travelerCount : 1) : (kind == .hotel ? quantity : 1)
        return unitPrice * Int64(units) * Int64(days(in: claim))
    }
    func formula(in claim: Claim) -> String {
        switch kind {
        case .subsidy: return "\(claimant == nil ? claim.travelerCount : 1) 人 × \(Money.format(unitPrice)) × \(days(in: claim)) 天"
        case .hotel: return "住宿总价（\(days(in: claim)) 晚）"
        case .meal, .allowance: return "\(days(in: claim)) 天 × \(Money.format(unitPrice))"
        default: return "按实际交通费用"
        }
    }
    var invoiceTotal: Int64 { invoices.reduce(0) { $0 + $1.amount } }
}

struct Claim: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var kind: ClaimKind
    var travelers = 1
    var travelerNames: [String]?
    var travelerCount: Int { travelerNames?.count ?? travelers }
    @discardableResult mutating func renameTraveler(from old: String, to new: String) -> Bool {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = travelerNames?.firstIndex(of: old), !name.isEmpty,
              name == old || !(travelerNames ?? []).contains(name) else { return false }
        travelerNames?[index] = name
        for index in expenses.indices where expenses[index].claimant == old { expenses[index].claimant = name }
        return true
    }
    mutating func setTravelerNames(_ names: [String]) {
        let previous = travelerNames ?? []
        var seen = Set<String>()
        travelerNames = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        travelers = travelerNames!.count
        let removed = Set(previous).subtracting(travelerNames!)
        let added = travelerNames!.filter { !previous.contains($0) }
        let templates = expenses.filter { $0.subsidyGroupID != nil }
        expenses.removeAll { $0.kind == .subsidy && $0.subsidyGroupID != nil && removed.contains($0.claimant ?? "") && $0.invoices.isEmpty }
        // Keep a zero-person template if the last name is removed, so its price and dates survive.
        if travelerNames!.isEmpty {
            for template in templates where !expenses.contains(where: { $0.subsidyGroupID == template.subsidyGroupID }) {
                var placeholder = template
                placeholder.claimant = nil
                expenses.append(placeholder)
            }
        }
        assignPeopleIfNeeded()
        var visited = Set<UUID>()
        for template in templates {
            guard let group = template.subsidyGroupID, visited.insert(group).inserted else { continue }
            for name in added where !expenses.contains(where: { $0.subsidyGroupID == group && $0.claimant == name }) {
                var expense = template
                expense.id = UUID(); expense.claimant = name; expense.invoices = []
                expenses.append(expense)
            }
        }
    }
    var dates: Set<String> = []
    var note = ""
    var expenses: [Expense] = []
    var expenseOrder: [ExpenseKind]?
    var covers: [Attachment] = []
    var createdAt = Date()
    var updatedAt = Date()

    static func make(_ kind: ClaimKind, date: Date = Date()) -> Claim {
        let suffix = DayKey.string(date).replacingOccurrences(of: "-", with: "")
        var claim = Claim(title: "\(kind.rawValue)报销\(suffix)", kind: kind, createdAt: date, updatedAt: date)
        claim.setTravelerNames([])
        claim.expenses = [Expense(kind: kind.categories[0])]
        return claim
    }
    // Legacy aggregate subsidies are expanded once; originals and attachments stay on the first row.
    mutating func assignPeopleIfNeeded() {
        guard let names = travelerNames, let first = names.first else { return }
        expenses = expenses.flatMap { original -> [Expense] in
            guard original.claimant == nil else { return [original] }
            if original.kind == .subsidy {
                return names.enumerated().map { index, name in
                    var expense = original
                    expense.claimant = name; expense.subsidyGroupID = original.subsidyGroupID ?? original.id
                    if index > 0 { expense.id = UUID(); expense.invoices = [] }
                    return expense
                }
            }
            var expense = original
            expense.claimant = first
            return [expense]
        }
    }
    var withPeopleAssigned: Claim {
        var claim = self
        // Restore daily calculations for records previously linked to invoice totals.
        for index in claim.expenses.indices where !claim.expenses[index].synchronizesInvoiceTotal {
            claim.expenses[index].totalAmount = nil
            claim.expenses[index].invoiceTotalLinked = nil
        }
        claim.assignPeopleIfNeeded()
        return claim
    }
    var withDirectHotelTotals: Claim {
        var claim = self
        for index in claim.expenses.indices where claim.expenses[index].kind == .hotel && claim.expenses[index].totalAmount == nil {
            claim.expenses[index].totalAmount = claim.expenses[index].total(in: self)
        }
        return claim
    }
    mutating func addExpense(_ kind: ExpenseKind, unitPrice: Int64) {
        expenses.append(Expense(kind: kind, unitPrice: unitPrice, claimant: kind == .subsidy ? nil : travelerNames?.first, totalAmount: kind == .hotel ? unitPrice : nil))
        assignPeopleIfNeeded()
        if expenseOrder != nil && !expenseOrder!.contains(kind) { expenseOrder!.append(kind) }
    }
    var personBreakdowns: [PersonBreakdown] {
        let assigned = withPeopleAssigned
        var names = travelerNames ?? []
        for name in assigned.expenses.compactMap(\.claimant) where !names.contains(name) { names.append(name) }
        var people = names.map { name in PersonBreakdown(claimant: name, expenses: assigned.expenses.filter { $0.claimant == name }) }
        let unassigned = assigned.expenses.filter { $0.claimant == nil }
        if !unassigned.isEmpty { people.append(PersonBreakdown(claimant: nil, expenses: unassigned)) }
        return people
    }
    var total: Int64 { expenses.reduce(0) { $0 + $1.total(in: self) } }
    var reimbursementDayCount: Int { personBreakdowns.map { $0.days(in: self) }.max() ?? dates.count }
    var reimbursementDates: Set<String> {
        let resolved = personBreakdowns.reduce(into: Set<String>()) { $0.formUnion($1.dates(in: self)) }
        return resolved.isEmpty ? dates : resolved
    }
    var invoiceTotal: Int64 { expenses.reduce(0) { $0 + $1.invoiceTotal } }
    var invoiceCount: Int { expenses.reduce(0) { $0 + $1.invoices.count } }
    var difference: Int64 { total - invoiceTotal }
    var attachments: [Attachment] { covers + expenses.flatMap(\.attachments) }
    var expenseGroups: [ExpenseGroup] {
        var seen = Set<ExpenseKind>()
        return ((expenseOrder ?? []) + ExpenseKind.allCases).filter { seen.insert($0).inserted }.compactMap { kind in
            let items = expenses.filter { $0.kind == kind }
            return items.isEmpty ? nil : ExpenseGroup(kind: kind, expenses: items)
        }
    }
    mutating func moveExpenseGroup(_ kind: ExpenseKind, to index: Int) {
        var order = expenseGroups.map(\.kind)
        guard let old = order.firstIndex(of: kind), order.indices.contains(index), old != index else { return }
        order.remove(at: old)
        order.insert(kind, at: index)
        expenseOrder = order
    }
    var dateSummary: String {
        let sorted = dates.sorted()
        guard let first = sorted.first, let last = sorted.last else { return "尚未选择日期" }
        return first == last ? first : "\(first) 至 \(last) · \(sorted.count) 天"
    }
}

struct PersonBreakdown: Identifiable {
    var claimant: String?
    var expenses: [Expense]
    var id: String { claimant.map { "person:\($0)" } ?? "unassigned" }
    var name: String { claimant ?? "未分配" }
    var invoiceCount: Int { expenses.reduce(0) { $0 + $1.invoices.count } }
    var invoiceTotal: Int64 { expenses.reduce(0) { $0 + $1.invoiceTotal } }
    func total(in claim: Claim) -> Int64 { expenses.reduce(0) { $0 + $1.total(in: claim) } }
    func dates(in claim: Claim) -> Set<String> {
        guard !expenses.isEmpty else { return [] }
        // Allowance calendars define a person's trip; transport and hotel dates must not inflate it.
        let allowances = expenses.filter { [.subsidy, .meal, .allowance].contains($0.kind) }
        if !allowances.isEmpty { return allowances.reduce(into: Set<String>()) { $0.formUnion($1.dates ?? claim.dates) } }
        let dated = expenses.filter { $0.dates != nil }
        if dated.isEmpty { return claim.dates }
        return dated.reduce(into: Set<String>()) { result, expense in
            result.formUnion(expense.dates ?? [])
            if expense.kind == .hotel, let last = expense.dates?.sorted().last.flatMap(DayKey.date),
               let checkout = DayKey.calendar.date(byAdding: .day, value: 1, to: last) {
                result.insert(DayKey.string(checkout))
            }
        }
    }
    func days(in claim: Claim) -> Int { dates(in: claim).count }
}

struct ExpenseGroup: Identifiable {
    var kind: ExpenseKind
    var expenses: [Expense]
    var id: ExpenseKind { kind }
    var invoiceCount: Int { expenses.reduce(0) { $0 + $1.invoices.count } }
    var invoiceTotal: Int64 { expenses.reduce(0) { $0 + $1.invoiceTotal } }
    func total(in claim: Claim) -> Int64 { expenses.reduce(0) { $0 + $1.total(in: claim) } }
}
