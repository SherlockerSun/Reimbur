import Foundation

struct ClaimPeriodFilter: Equatable {
    var year: Int = 0
    var month: Int = 0
    static func date(for claim: Claim) -> Date { claim.dates.sorted().first.flatMap(DayKey.date) ?? claim.createdAt }
    func matches(_ claim: Claim) -> Bool {
        let parts = DayKey.calendar.dateComponents([.year, .month], from: Self.date(for: claim))
        return (year == 0 || parts.year == year) && (month == 0 || parts.month == month)
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
        if !(claim.travelerNames ?? []).isEmpty || claim.expenses.contains(where: { $0.claimant != nil }) {
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
}
