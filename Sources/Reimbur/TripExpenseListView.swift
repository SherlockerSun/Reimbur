import SwiftUI

enum TripExpenseColumns {
    static func columns(for kind: ExpenseKind) -> [ReimbursementColumn] {
        let sequence = ReimbursementColumn(id: "sequence", title: "序号", width: 48, minimum: 44, alignment: .center)
        let person = ReimbursementColumn(id: "person", title: "报销人", width: 100, minimum: 88)
        let operations = ReimbursementColumn(id: "operations", title: "操作", width: 108, minimum: 108, alignment: .center)
        if kind == .subsidy {
            return [sequence, ReimbursementColumn(id: "person", title: "报销人", width: 120, minimum: 88),
                    ReimbursementColumn(id: "days", title: "天数", width: 100, minimum: 88),
                    ReimbursementColumn(id: "price", title: "单价（元 / 天）", width: 132, minimum: 124, alignment: .center),
                    ReimbursementColumn(id: "total", title: "合计（元）", width: 116, minimum: 108, alignment: .center),
                    ReimbursementColumn(id: "note", title: "备注", width: 280, minimum: 140, growth: 1), operations]
        }
        var columns = [sequence, person]
        if kind.hasRoute {
            if kind == .train { columns.append(ReimbursementColumn(id: "departure", title: "出发日期", width: 120, minimum: 112)) }
            columns.append(ReimbursementColumn(id: "origin", title: "起始地", width: 104, minimum: 88))
            if kind == .train { columns.append(ReimbursementColumn(id: "arrival", title: "到达日期", width: 120, minimum: 112)) }
            columns.append(ReimbursementColumn(id: "destination", title: "目的地", width: 104, minimum: 88))
        } else if kind == .hotel { columns.append(ReimbursementColumn(id: "days", title: "入住晚数", width: 100, minimum: 92)) }
        columns += [ReimbursementColumn(id: "number", title: "发票号码", width: 180, minimum: 160),
                    ReimbursementColumn(id: "invoice", title: "发票", width: kind == .taxi ? 276 : 280, minimum: 190, growth: 1)]
        if kind == .taxi { columns.append(ReimbursementColumn(id: "itinerary", title: "行程单", width: 276, minimum: 190, growth: 1)) }
        columns += [ReimbursementColumn(id: "amount", title: "发票金额（元）", width: 116, minimum: 110, alignment: .center), operations]
        return columns
    }
    static func titles(for kind: ExpenseKind) -> [String] { columns(for: kind).map(\.title) }
    static func rowHeight(for expense: Expense) -> CGFloat { max(60, CGFloat(max(expense.invoices.count, (expense.itineraries ?? []).count) * 40 + 16)) }
    static func widths(for available: CGFloat, kind: ExpenseKind) -> [CGFloat] { ReimbursementColumnSizing.widths(columns(for: kind), available: available, overrides: [:]) }
}

struct TripExpenseListView: View {
    @Binding var claim: Claim
    var kind: ExpenseKind
    var remove: (UUID) -> Void
    var files = ExpenseFileActions()
    @State private var sortingColumn: String?
    private var expenses: [Expense] {
        let rows = claim.expenses.filter { $0.kind == kind }
        return kind == .train && sortingColumn == nil ? RailMoment.ordered(rows) : rows
    }
    var body: some View {
        VStack(spacing: 14) {
            ReimbursementTable(id: "trip.\(kind.id)", columns: TripExpenseColumns.columns(for: kind), rows: expenses,
                               rowHeight: TripExpenseColumns.rowHeight,
                               sort: { sortingColumn = $1 == nil ? nil : $0; claim.sortExpenses(kind, column: $0, ascending: $1) }) { expense, index, column in
                TripExpenseCell(claim: $claim, expense: expense, number: index + 1, column: column, files: files, remove: { remove(expense.id) })
            }.id(kind.id)
            if let group = claim.expenseGroups.first(where: { $0.kind == kind }) {
                HStack {
                    Text("\(expenses.count) 笔 · 合计 \(Money.format(group.total(in: claim)))").foregroundStyle(Palette.accent)
                    Spacer(minLength: 12)
                    if kind.acceptsInvoices { Text("\(group.invoiceCount) 份发票 · 票面 \(Money.format(group.invoiceTotal))") }
                }.font(.system(size: 11)).monospacedDigit()
            }
        }.onChange(of: kind) { _, _ in sortingColumn = nil }
            .onChange(of: claim.id) { _, _ in sortingColumn = nil }
    }
}

private struct TripExpenseCell: View {
    @Binding var claim: Claim
    var expense: Expense
    var number: Int
    var column: ReimbursementColumn
    var files: ExpenseFileActions
    var remove: () -> Void
    private var current: Expense { claim.expenses.first { $0.id == expense.id } ?? expense }
    private var names: [String] {
        var names = claim.travelerNames ?? []
        if let name = current.claimant, !names.contains(name) { names.append(name) }
        return names
    }
    private func field<Value>(_ keyPath: WritableKeyPath<Expense, Value>) -> Binding<Value> {
        Binding(get: { current[keyPath: keyPath] }, set: { value in
            guard let index = claim.expenses.firstIndex(where: { $0.id == expense.id }) else { return }
            claim.expenses[index][keyPath: keyPath] = value
        })
    }
    var body: some View {
        Group {
            switch column.id {
            case "departure": RailDateField(value: field(\.departureTime), title: "出发日期", fallbackDate: claim.dates.sorted().first.flatMap(DayKey.date) ?? claim.createdAt)
            case "arrival": RailDateField(value: Binding(get: { current.effectiveArrivalDate }, set: { value in
                field(\.arrivalTime).wrappedValue = RailMoment.dayKey(value) == RailMoment.dayKey(current.departureTime) ? nil : value
            }), title: "到达日期", fallbackDate: RailMoment.date(current.departureTime) ?? claim.dates.sorted().first.flatMap(DayKey.date) ?? claim.createdAt)
            case "person": TablePersonField(selection: field(\.claimant), names: names)
            case "origin": TablePlaceField(text: field(\.originCity), placeholder: "起始地").help(current.originCity)
            case "destination": TablePlaceField(text: field(\.destinationCity), placeholder: "目的地").help(current.destinationCity)
            case "days": TripExpenseDatesField(claim: $claim, expenseID: expense.id).frame(maxWidth: .infinity, alignment: .center)
            case "price":
                AmountField(cents: Binding(get: { current.unitPrice }, set: { value in
                    guard let index = claim.expenses.firstIndex(where: { $0.id == expense.id }), current.unitPrice != value else { return }
                    claim.expenses[index].setDailyPrice(value)
                })).multilineTextAlignment(.center).help(Money.format(current.unitPrice)).accessibilityLabel("补助单价 \(number)")
            case "note": TextField("填写备注", text: field(\.note)).help(current.note).accessibilityLabel("费用备注 \(number)")
            case "total": Text(Money.input(current.total(in: claim))).foregroundStyle(Palette.accent).monospacedDigit().help(Money.format(current.total(in: claim)))
            case "number": invoiceNumbers
            case "invoice":
                VStack(spacing: 8) {
                    if current.invoices.isEmpty { placeholder("未上传") }
                    ForEach(current.invoices) { invoice in InvoiceFileCell(attachment: invoice, expenseID: expense.id, actions: files) }
                }
            case "itinerary":
                VStack(spacing: 8) {
                    ForEach(Array(current.itinerarySlots.enumerated()), id: \.offset) { _, attachment in
                        if let attachment { InvoiceFileCell(attachment: attachment, expenseID: expense.id, actions: files) }
                        else { placeholder("未上传").frame(height: 32) }
                    }
                    if current.itinerarySlots.isEmpty { placeholder("未上传") }
                }
            case "amount": invoiceAmounts
            case "operations": operations
            default: EmptyView()
            }
        }.font(.system(size: 11)).textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
    }
    private func placeholder(_ text: String) -> some View { Text(text).foregroundStyle(Palette.muted.opacity(0.75)).frame(maxWidth: .infinity, alignment: .center) }
    private var invoiceNumbers: some View {
        VStack(spacing: 8) {
            if current.invoices.isEmpty { placeholder("—") }
            ForEach(current.invoices) { invoice in
                TextField("发票号码", text: Binding(get: { self.current.invoices.first { $0.id == invoice.id }?.number ?? "" }, set: { value in
                    guard let index = claim.expenses.firstIndex(where: { $0.id == expense.id }),
                          let file = claim.expenses[index].invoices.firstIndex(where: { $0.id == invoice.id }) else { return }
                    claim.expenses[index].invoices[file].number = value
                })).monospacedDigit().frame(height: 32).help(invoice.number ?? "未识别发票号码").accessibilityLabel("费用发票号码 \(number) · \(invoice.name)")
            }
        }
    }
    private var invoiceAmounts: some View {
        VStack(spacing: 8) {
            if current.invoices.isEmpty { Text("—").foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .center) }
            ForEach(current.invoices) { invoice in
                AmountField(cents: Binding(get: { self.current.invoices.first { $0.id == invoice.id }?.amount ?? 0 }, set: { amount in
                    guard let index = claim.expenses.firstIndex(where: { $0.id == expense.id }),
                          let file = claim.expenses[index].invoices.firstIndex(where: { $0.id == invoice.id }) else { return }
                    claim.expenses[index].invoices[file].amount = amount
                    claim.expenses[index].synchronizeInvoiceTotal()
                })).multilineTextAlignment(.center).frame(height: 32).help(Money.format(invoice.amount))
                    .accessibilityLabel("费用发票金额 \(number) · \(invoice.name)")
            }
        }.monospacedDigit()
    }
    private var operations: some View {
        HStack(spacing: 3) {
            TableActionButton(title: "复制第\(number)行", icon: "doc.on.doc") { files.duplicateExpense(expense.id) }
            if current.kind.acceptsInvoices {
                TableActionPopover(title: "第\(number)行附件操作", icon: "square.and.arrow.up") { dismiss in
                    Button("上传发票", systemImage: "doc.badge.plus") { dismiss(); files.upload(expense.id, .invoice) }
                    if current.kind == .taxi {
                        Button("上传行程单", systemImage: "list.bullet.rectangle") { dismiss(); files.upload(expense.id, .itinerary) }
                            .disabled((current.itineraries ?? []).count >= max(1, current.invoices.count))
                    }
                    if !current.attachments.isEmpty {
                        Divider()
                        Menu("移除附件") {
                            ForEach(current.attachments) { attachment in
                                Button(attachment.name, role: .destructive) { dismiss(); files.remove(attachment, expense.id) }
                            }
                        }
                    }
                    if current.kind == .taxi, !(current.itineraries ?? []).isEmpty {
                        Menu("调整行程单归属") {
                            ForEach(current.itineraries ?? []) { attachment in
                                Menu(attachment.name) {
                                    ForEach(claim.expenses.filter { $0.kind == .taxi && $0.id != expense.id && !$0.invoices.isEmpty && ($0.itineraries ?? []).count < $0.invoices.count }) { target in
                                        Button("\(target.claimant ?? "未分配") · \(target.invoices.first?.number ?? target.invoices.first?.name ?? "发票")") {
                                            dismiss(); files.move(attachment, expense.id, target.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            TableActionButton(title: "删除第\(number)行", icon: "trash", destructive: true, action: remove)
        }
    }
}

struct TripExpenseDatesField: View {
    @Binding var claim: Claim
    var expenseID: UUID
    @State private var showing = false
    private var expense: Expense? { claim.expenses.first { $0.id == expenseID } }
    private var dateHelp: String {
        guard let expense else { return "设置日期" }
        let dates = expense.dates ?? (expense.kind == .hotel ? expense.defaultStayDates(in: claim) : claim.dates)
        return dates.sorted().joined(separator: "、") + "\n点击设置本笔费用的独立日期"
    }
    var body: some View {
        Button { showing.toggle() } label: {
            Label("\(expense?.days(in: claim) ?? 0) \(expense?.kind == .hotel ? "晚" : "天")", systemImage: "calendar")
                .font(.system(size: 11)).foregroundStyle(Palette.accent).padding(.horizontal, 8).frame(height: 27)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.ink.opacity(0.12)))
        }.buttonStyle(.plain).help(dateHelp)
            .popover(isPresented: $showing) {
                if let expense {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(expense.kind == .hotel ? "入住日期" : "补助日期").font(.system(size: 13, weight: .semibold))
                        Toggle("单独选择日期", isOn: Binding(get: { self.expense?.dates != nil }, set: { enabled in
                            guard let index = claim.expenses.firstIndex(where: { $0.id == expenseID }) else { return }
                            claim.expenses[index].dates = enabled ? (expense.kind == .hotel ? expense.defaultStayDates(in: claim) : claim.dates) : nil
                        })).toggleStyle(.switch).controlSize(.small)
                        if expense.dates != nil {
                            CalendarPicker(selection: Binding(get: { self.expense?.dates ?? [] }, set: { dates in
                                guard let index = claim.expenses.firstIndex(where: { $0.id == expenseID }) else { return }
                                claim.expenses[index].dates = dates
                            })).frame(width: 270)
                        } else {
                            Text(expense.kind == .hotel ? "随报销日历计算，\(claim.dates.count) 天 \(expense.days(in: claim)) 晚。" : "随报销日历计算，共 \(expense.days(in: claim)) 天。")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }.padding(16).frame(width: 306)
                }
            }
    }
}
