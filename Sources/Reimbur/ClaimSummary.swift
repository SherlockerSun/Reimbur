import Foundation

struct ClaimPeriodFilter: Equatable {
    var year: Int = 0
    var month: Int = 0
    static func date(for claim: Claim) -> Date {
        claim.kind == .allowance ? claim.createdAt : claim.dates.sorted().first.flatMap(DayKey.date) ?? claim.createdAt
    }
    func matches(_ claim: Claim) -> Bool {
        let parts = DayKey.calendar.dateComponents([.year, .month], from: Self.date(for: claim))
        return (year == 0 || parts.year == year) && (month == 0 || parts.month == month)
    }
}

struct ClaimRecordFilter {
    var kind: ClaimKind?
    var status: ClaimStatus?
    var period = ClaimPeriodFilter()
    var search = ""
    func matches(_ claim: Claim) -> Bool {
        (kind == nil || claim.kind == kind) && (status == nil || claim.status == status) && period.matches(claim) &&
        (search.isEmpty || claim.title.localizedCaseInsensitiveContains(search) || claim.note.localizedCaseInsensitiveContains(search) ||
         (claim.travelerNames ?? []).contains { $0.localizedCaseInsensitiveContains(search) })
    }
}

struct ClaimStatusSummary: Identifiable {
    var status: ClaimStatus
    var records: [Claim]
    var id: ClaimStatus { status }
    var total: Int64 { records.reduce(0) { $0 + $1.total } }
    var invoiceTotal: Int64 { records.reduce(0) { $0 + $1.invoiceTotal } }
    static func all(in claims: [Claim], period: ClaimPeriodFilter) -> [Self] {
        let records = claims.filter(period.matches)
        return ClaimStatus.allCases.map { status in Self(status: status, records: records.filter { $0.status == status }) }
    }
}

enum ClaimSummary {
    static func ranges(_ dates: Set<String>) -> String {
        let sorted = dates.sorted()
        guard let first = sorted.first else { return "未选择日期" }
        var start = first, end = first
        var segments: [String] = []
        func segment() -> String { start == end ? start : "\(start)~\(end)" }
        for key in sorted.dropFirst() {
            if let previous = DayKey.date(end), let next = DayKey.calendar.date(byAdding: .day, value: 1, to: previous), DayKey.string(next) == key { end = key }
            else { segments.append(segment()); start = key; end = key }
        }
        segments.append(segment())
        return segments.joined(separator: "、")
    }
    static func renderOverview(_ claim: Claim) -> String { renderSection(claim.withPeopleAssigned) }
    static func render(_ claim: Claim) -> String {
        let claim = claim.withPeopleAssigned
        var text = renderSection(claim)
        if claim.kind == .trip && (!(claim.travelerNames ?? []).isEmpty || claim.expenses.contains(where: { $0.claimant != nil })) {
            for person in claim.personBreakdowns {
                text += "\n\n" + String(repeating: "=", count: 54) + "\n\n" + renderPerson(claim, person: person)
            }
        }
        return text
    }
    static func renderPerson(_ claim: Claim, person: PersonBreakdown) -> String {
        var individual = claim.withPeopleAssigned
        individual.expenses = person.expenses
        return renderSection(individual, person: person)
    }
    private static func renderSection(_ claim: Claim, person: PersonBreakdown? = nil) -> String {
        if claim.kind != .trip, claim.invoiceLedgerEntries != nil { return renderLedger(claim) }
        var lines = [claim.title, "类型：\(claim.kind.rawValue)报销"]
        if let person {
            if claim.kind == .trip { lines.append("出差人：\(person.name)") }
        } else if claim.kind == .trip {
            let people = claim.travelerNames.map { $0.isEmpty ? "未填写" : $0.joined(separator: "、") } ?? "历史记录，尚未填写姓名"
            lines.append("出差人：\(people)（\(claim.travelerCount) 人）")
        } else if let names = claim.travelerNames, !names.isEmpty {
            lines.append("报销人：\(names.joined(separator: "、"))（\(names.count) 人）")
        }
        let dates = person?.dates(in: claim) ?? claim.reimbursementDates
        let days = person?.days(in: claim) ?? claim.reimbursementDayCount
        lines.append("日期：\(ranges(dates))（\(days) 天）")
        for (index, group) in claim.expenseGroups.enumerated() {
            lines += ["", "\(index + 1)、\(group.kind.rawValue)"]
            if group.kind.hasRoute {
                var routes: [String] = []
                var amounts: [String: [Int64]] = [:]
                for expense in group.expenses {
                    let route = "\(expense.origin.isEmpty ? "未填起点" : expense.origin)-\(expense.destination.isEmpty ? "未填终点" : expense.destination)"
                    if amounts[route] == nil { routes.append(route) }
                    amounts[route, default: []].append(expense.total(in: claim))
                }
                for route in routes {
                    let values = amounts[route]!
                    lines.append("    \(route)：\(values.map(Money.input).joined(separator: "+"))=\(Money.input(values.reduce(0,+)))")
                }
            } else {
                for expense in group.expenses {
                    if !expense.kind.isTransport { lines.append("    时间：\(ranges(expense.dates ?? claim.dates))") }
                    if expense.kind == .hotel {
                        lines.append("    住宿：\(expense.days(in: claim)) 晚" + (expense.dates == nil ? "（\(claim.dates.count) 天 \(expense.days(in: claim)) 晚）" : "（单独选择的入住日期）"))
                    }
                    lines.append("    \(expense.formula(in: claim)) = \(Money.input(expense.total(in: claim)))")
                    if !expense.note.isEmpty { lines.append("    说明：\(expense.note)") }
                }
            }
            if group.kind.acceptsInvoices || group.invoiceCount > 0 { lines.append("    张数：\(group.invoiceCount) 张；票面金额：\(Money.input(group.invoiceTotal))") }
            lines.append("    共计：\(group.expenses.map { Money.input($0.total(in: claim)) }.joined(separator: "+"))=\(Money.input(group.total(in: claim)))")
        }
        lines += ["", "*总数：\(claim.invoiceCount) 张", "*总额：\(claim.expenseGroups.map { Money.input($0.total(in: claim)) }.joined(separator: "+"))=\(Money.input(claim.total))", "*发票金额：\(Money.input(claim.invoiceTotal))", "*差额（总额－发票金额）：\(Money.input(claim.difference))"]
        if !claim.note.isEmpty { lines += ["", "备注：\(claim.note)"] }
        return lines.joined(separator: "\n")
    }
    private static func renderLedger(_ claim: Claim) -> String {
        var lines = [claim.title, "类型：\(claim.kind.rawValue)报销", "报销人：\((claim.travelerNames ?? []).joined(separator: "、"))", "用途：\(claim.ledgerPurpose)"]
        if claim.kind == .meal {
            lines.append("日期：\(ranges(claim.dates))（\(claim.reimbursementDayCount) 天）")
            for expense in claim.expenses { lines.append("报销计算：\(expense.formula(in: claim)) = \(Money.input(expense.total(in: claim)))") }
        } else {
            lines.append("报销总额（单独填写）：\(Money.input(claim.total))")
        }
        lines += ["", "报销清单"]
        for (index, row) in claim.invoiceLedgerRows.enumerated() {
            lines += ["\(index + 1)、\(row.entry.date) · \(row.entry.claimant ?? "未填写")",
                      "    发票号码：\(row.invoice?.number ?? "未填写")",
                      "    发票金额：\(Money.input(row.invoice?.amount ?? 0))；报销单金额：\(Money.input(row.entry.reimbursementAmount))"]
            if !row.entry.detail.isEmpty { lines.append("    明细：\(row.entry.detail)") }
        }
        let total = claim.kind == .allowance ? Money.input(claim.total) : "\(claim.expenseGroups.map { Money.input($0.total(in: claim)) }.joined(separator: "+"))=\(Money.input(claim.total))"
        lines += ["", "*总数：\(claim.invoiceCount) 张", "*总额：\(total)", "*发票金额：\(Money.input(claim.invoiceTotal))",
                  "*清单报销单金额合计：\(Money.input(claim.ledgerReimbursementTotal))", "*差额（总额－发票金额）：\(Money.input(claim.difference))"]
        if !claim.note.isEmpty { lines += ["", "备注：\(claim.note)"] }
        return lines.joined(separator: "\n")
    }
}
