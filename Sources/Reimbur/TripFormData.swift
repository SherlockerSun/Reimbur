import Foundation

struct TripFormData {
    struct OtherCost {
        var title: String
        var count: Int
        var amount: Int64
    }
    var claim: Claim
    var person: PersonBreakdown?
    var expenses: [Expense]
    var legs: [Expense]
    var subsidies: [Int: Int64] = [:]
    var otherCosts: [OtherCost] = []
    var rowCount: Int = 7
    var name: String { person?.name ?? (claim.travelerNames ?? []).joined(separator: "、") }
    var total: Int64 { expenses.reduce(0) { $0 + $1.total(in: claim) } }
    var fare: Int64 { legs.reduce(0) { $0 + $1.total(in: claim) } }
    var subsidy: Int64 { subsidies.values.reduce(0, +) }
    var otherTotal: Int64 { otherCosts.reduce(0) { $0 + $1.amount } }
    var invoiceCount: Int { expenses.reduce(0) { $0 + $1.invoices.count } }
    var dates: Set<String> { person?.dates(in: claim) ?? claim.reimbursementDates }

    init(claim: Claim, person: PersonBreakdown? = nil) {
        self.claim = claim
        self.person = person
        expenses = person?.expenses ?? claim.withPeopleAssigned.expenses
        legs = RailMoment.ordered(expenses.filter { $0.kind == .train || $0.kind == .flight })
        func cost(_ title: String, kind: ExpenseKind?) -> OtherCost {
            let items = expenses.filter { $0.kind == kind }
            return OtherCost(title: title, count: items.reduce(0) { $0 + $1.invoices.count }, amount: items.reduce(0) { $0 + $1.total(in: claim) })
        }
        otherCosts = [cost("行李费", kind: nil), cost("市内车费", kind: .taxi), cost("住宿费", kind: .hotel),
                      cost("邮电费", kind: nil), cost("不买卧铺补贴", kind: nil)]
        // A subsidy date block belongs on its return leg where one is recorded.
        // Unmatched blocks receive their own blank travel row, never an invented route.
        var extra = legs.count
        for expense in expenses where expense.kind == .subsidy {
            let days = (expense.dates ?? claim.dates).sorted()
            var blocks: [[String]] = []
            for day in days {
                if let last = blocks.last?.last, let date = DayKey.date(last),
                   let next = DayKey.calendar.date(byAdding: .day, value: 1, to: date), DayKey.string(next) == day {
                    blocks[blocks.count - 1].append(day)
                } else { blocks.append([day]) }
            }
            for block in blocks {
                let amount = expense.unitPrice * Int64(block.count) * Int64(expense.claimant == nil ? claim.travelerCount : 1)
                guard amount != 0 else { continue }
                let index: Int
                if let end = block.last, let matching = legs.lastIndex(where: { String(($0.departureTime ?? "").prefix(10)) == end }) { index = matching }
                else { index = extra; extra += 1 }
                subsidies[index, default: 0] += amount
            }
        }
        rowCount = max(7, max(extra, max(legs.count, otherCosts.count)))
    }
    static func momentParts(_ value: String?, place: String) -> [String] {
        guard let date = RailMoment.date(value) else { return ["", "", "", place] }
        let parts = DayKey.calendar.dateComponents([.month, .day], from: date)
        return [String(parts.month ?? 0), String(parts.day ?? 0), "", place]
    }
}

enum ChineseMoney {
    static func uppercase(_ cents: Int64) -> String {
        let value = max(0, cents), yuan = value / 100
        let digits = ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"]
        func group(_ number: Int64) -> String {
            let places: [Int64] = [1000, 100, 10, 1], units = ["仟", "佰", "拾", ""]
            var text = "", pendingZero = false
            for (index, place) in places.enumerated() {
                let digit = Int(number / place % 10)
                if digit == 0 { if !text.isEmpty { pendingZero = true } }
                else {
                    if pendingZero { text += "零"; pendingZero = false }
                    text += digits[digit] + units[index]
                }
            }
            return text
        }
        var remaining = yuan, groups: [Int64] = []
        repeat { groups.append(remaining % 10000); remaining /= 10000 } while remaining > 0
        let units = ["", "万", "亿", "兆", "京"]
        var text = "", zero = false
        for index in groups.indices.reversed() {
            let part = groups[index]
            if part == 0 { if !text.isEmpty { zero = true }; continue }
            if !text.isEmpty && (zero || part < 1000) { text += "零" }
            zero = false
            text += group(part) + units[index]
        }
        text = (text.isEmpty ? "零" : text) + "元"
        let jiao = Int(value / 10 % 10), fen = Int(value % 10)
        if jiao == 0 && fen == 0 { return text + "整" }
        if jiao > 0 { text += digits[jiao] + "角" }
        else if yuan > 0 { text += "零" }
        if fen > 0 { text += digits[fen] + "分" }
        return text
    }
}
