import Foundation

enum ReimbursementSortValue {
    case text(String), number(Int64)
    func compare(_ other: ReimbursementSortValue) -> ComparisonResult {
        switch (self, other) {
        case let (.number(a), .number(b)): return a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
        case let (.text(a), .text(b)): return a.localizedStandardCompare(b)
        default: return .orderedSame
        }
    }
}

extension Claim {
    mutating func sortExpenses(_ kind: ExpenseKind, column: String, ascending: Bool?) {
        defaultExpenseRowOrder = Self.mergedRowOrder(defaultExpenseRowOrder, current: expenses.map(\.id))
        let ranks = Dictionary(uniqueKeysWithValues: (defaultExpenseRowOrder ?? []).enumerated().map { ($0.element, $0.offset) })
        let snapshot = self
        let slots = expenses.indices.filter { expenses[$0].kind == kind }
        let sorted = slots.map { expenses[$0] }.sorted { a, b in
            if let ascending {
                let order = a.sortValue(column, in: snapshot).compare(b.sortValue(column, in: snapshot))
                if order != .orderedSame { return order == (ascending ? .orderedAscending : .orderedDescending) }
            }
            return ranks[a.id, default: Int.max] < ranks[b.id, default: Int.max]
        }
        for (slot, expense) in zip(slots, sorted) { expenses[slot] = expense }
    }
    mutating func sortLedgerRows(column: String, ascending: Bool?) {
        defaultLedgerRowOrder = Self.mergedRowOrder(defaultLedgerRowOrder, current: invoiceLedgerRows.map(\.id))
        let ranks = Dictionary(uniqueKeysWithValues: (defaultLedgerRowOrder ?? []).enumerated().map { ($0.element, $0.offset) })
        let purpose = ledgerPurpose
        invoiceLedgerEntries = invoiceLedgerRows.sorted { a, b in
            if let ascending {
                let order = a.sortValue(column, purpose: purpose).compare(b.sortValue(column, purpose: purpose))
                if order != .orderedSame { return order == (ascending ? .orderedAscending : .orderedDescending) }
            }
            return ranks[a.id, default: Int.max] < ranks[b.id, default: Int.max]
        }.map(\.entry)
        let invoiceRanks = Dictionary((invoiceLedgerEntries ?? []).enumerated().compactMap { index, entry in entry.invoiceID.map { ($0, index) } }, uniquingKeysWith: min)
        for index in expenses.indices { expenses[index].invoices.sort { invoiceRanks[$0.id, default: Int.max] < invoiceRanks[$1.id, default: Int.max] } }
    }
    // Retain the original order across saves; append new rows and discard deleted IDs.
    private static func mergedRowOrder(_ saved: [UUID]?, current: [UUID]) -> [UUID] {
        let existing = Set(current)
        var seen = Set<UUID>()
        return ((saved ?? []) + current).filter { existing.contains($0) && seen.insert($0).inserted }
    }
}

private extension Expense {
    func sortValue(_ column: String, in claim: Claim) -> ReimbursementSortValue {
        switch column {
        case "person": return .text(claimant ?? "")
        case "departure": return .text(RailMoment.dayKey(departureTime) ?? "9999-12-31")
        case "arrival": return .text(effectiveArrivalDate ?? "9999-12-31")
        case "origin": return .text(originCity)
        case "destination": return .text(destinationCity)
        case "days": return .number(Int64(days(in: claim)))
        case "price": return .number(unitPrice)
        case "total": return .number(total(in: claim))
        case "note": return .text(note)
        case "number": return .text(invoices.compactMap(\.number).joined(separator: " "))
        case "invoice": return .text(invoices.map(\.name).joined(separator: " "))
        case "itinerary": return .text((itineraries ?? []).map(\.name).joined(separator: " "))
        case "amount": return .number(invoiceTotal)
        default: return .text("")
        }
    }
}

private extension InvoiceLedgerRow {
    func sortValue(_ column: String, purpose: String) -> ReimbursementSortValue {
        switch column {
        case "date": return .text(entry.date)
        case "person": return .text(entry.claimant ?? "")
        case "number": return .text(invoice?.number ?? "")
        case "invoice": return .text(invoice?.name ?? "")
        case "amount": return .number(invoice?.amount ?? 0)
        case "reimbursement": return .number(entry.reimbursementAmount)
        case "detail": return .text(entry.detail)
        case "purpose": return .text(purpose)
        default: return .text("")
        }
    }
}
