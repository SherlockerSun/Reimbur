import SwiftUI

private enum LedgerBatchAction: Identifiable {
    case claimant(String, Int)
    case delete([UUID])
    var id: String {
        switch self {
        case let .claimant(name, count): return "claimant-\(name)-\(count)"
        case let .delete(ids): return "delete-\(ids.map(\.uuidString).joined(separator: ","))"
        }
    }
}

enum InvoiceLedgerColumns {
    static let columns: [ReimbursementColumn] = [
        ReimbursementColumn(id: "sequence", title: "序号", width: 48, minimum: 44, alignment: .center),
        ReimbursementColumn(id: "date", title: "日期", width: 144, minimum: 140),
        ReimbursementColumn(id: "person", title: "报销人", width: 100, minimum: 88),
        ReimbursementColumn(id: "number", title: "发票号码", width: 180, minimum: 160),
        ReimbursementColumn(id: "invoice", title: "发票", width: 280, minimum: 190, growth: 1),
        ReimbursementColumn(id: "amount", title: "发票金额（元）", width: 116, minimum: 110, alignment: .center),
        ReimbursementColumn(id: "reimbursement", title: "报销单金额（元）", width: 132, minimum: 124, alignment: .center),
        ReimbursementColumn(id: "detail", title: "明细", width: 140, minimum: 100),
        ReimbursementColumn(id: "purpose", title: "用途", width: 110, minimum: 88),
        ReimbursementColumn(id: "operations", title: "操作", width: 108, minimum: 108, alignment: .center)
    ]
    static var titles: [String] { columns.map(\.title) }
    static func widths(for available: CGFloat) -> [CGFloat] { ReimbursementColumnSizing.widths(columns, available: available, overrides: [:]) }
}

struct InvoiceLedgerView: View {
    @Binding var claim: Claim
    var export: () -> Void
    var files = ExpenseFileActions()
    var renameAttachments: (Set<UUID>, String) -> Void = { _, _ in }
    @State private var tripRowsInTypeOrder = true
    @State private var selectedRows: Set<UUID> = []
    @State private var batchMode = false
    @State private var batchAction: LedgerBatchAction?
    private var claimantNames: [String] { claim.travelerNames ?? [] }

    var body: some View {
        Card {
            HStack {
                SectionLabel(title: "报销清单", subtitle: "发票与费用逐行核对")
                    .contextMenu { Button("导出报销清单（XLSX）", action: export) }
                    .help("右键清单标题可导出 XLSX")
                Spacer(minLength: 12)
                if batchMode {
                    Menu("变更报销人 \(selectedRows.count)") {
                        ForEach(claimantNames, id: \.self) { name in
                            Button(name) { batchAction = .claimant(name, selectedRows.count) }
                        }
                    }.buttonStyle(ExportButtonStyle(color: Palette.accent)).disabled(selectedRows.isEmpty || claimantNames.isEmpty)
                    Button("批量删除 \(selectedRows.count)", role: .destructive) { batchAction = .delete(Array(selectedRows)) }
                        .buttonStyle(ExportButtonStyle(color: .red)).disabled(selectedRows.isEmpty)
                    Button("完成") { batchMode = false }
                        .buttonStyle(ExportButtonStyle(color: Palette.muted))
                } else {
                    Button("批量操作") { batchMode = true }
                        .buttonStyle(ExportButtonStyle(color: Palette.accent))
                }
                Button(action: export) {
                    Label("导出", systemImage: "arrow.down.doc")
                }.buttonStyle(ExportButtonStyle(color: Palette.accent))
                    .help("导出报销清单（Excel）")
                    .accessibilityLabel("导出报销清单 Excel")

            }
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tablecells").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.accent)
                    Text("暂无发票，点击右上角“导入发票”添加").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
            } else {
                ReimbursementTable(id: "ledger.\(claim.kind.id)", columns: InvoiceLedgerColumns.columns, rows: rows,
                                   rowHeight: { _ in 60 }, sort: {
                                       if claim.kind == .trip { tripRowsInTypeOrder = $1 == nil }
                                       claim.sortLedgerRows(column: $0, ascending: $1)
                                   }, selectable: batchMode, selectedIDs: $selectedRows) { row, index, column in
                    InvoiceLedgerCell(claim: $claim, row: row, number: index + 1, column: column, files: files,
                                      batchMode: batchMode, selected: selectedRows.contains(row.id), toggleSelection: { value in
                                          if value { selectedRows.insert(row.id) } else { selectedRows.remove(row.id) }
                                      })
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { rowCount; Spacer(minLength: 0); invoiceTotal; reimbursementTotal }
                VStack(alignment: .leading, spacing: 8) { rowCount; invoiceTotal; reimbursementTotal }
            }.font(.system(size: 11)).monospacedDigit()
            HStack {
                Text("差额（报销总额 − 发票总额）").foregroundStyle(Palette.muted)
                Spacer()
                Text(Money.format(claim.difference)).fontWeight(.medium).monospacedDigit()
            }.font(.system(size: 11))
            Text(ledgerHint)
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        .onChange(of: claim.id) { _, _ in tripRowsInTypeOrder = true }
        .onChange(of: rows.map(\.id)) { _, ids in selectedRows = selectedRows.intersection(Set(ids)) }
        .onChange(of: batchMode) { _, enabled in if !enabled { selectedRows.removeAll() } }
        .confirmationDialog("确认批量操作", isPresented: Binding(get: { batchAction != nil }, set: { if !$0 { batchAction = nil } }), titleVisibility: .visible, presenting: batchAction) { action in
            switch action {
            case let .claimant(name, count):
                Button("确认变更 \(count) 行为“\(name)”") {
                    setClaimant(name)
                    batchAction = nil
                }
            case let .delete(ids):
                Button("确认删除 \(ids.count) 行", role: .destructive) {
                    deleteSelected()
                    batchAction = nil
                }
            }
            Button("取消", role: .cancel) { batchAction = nil }
        } message: { action in
            switch action {
            case let .claimant(_, count): Text("将变更所选的 \(count) 行及对应费用归属。")
            case let .delete(ids): Text("将删除所选的 \(ids.count) 行发票明细。")
            }
        }
    }
    private func setClaimant(_ name: String) {
        guard !selectedRows.isEmpty else { return }
        if var entries = claim.invoiceLedgerEntries {
            for index in entries.indices where selectedRows.contains(entries[index].id) {
                entries[index].claimant = name
            }
            // Keep personal detail totals aligned when every invoice of an expense
            // was selected; mixed attribution remains per-invoice in the ledger.
            for expenseIndex in claim.expenses.indices {
                let expenseRows = entries.filter { $0.expenseID == claim.expenses[expenseIndex].id }
                if !expenseRows.isEmpty && expenseRows.allSatisfy({ selectedRows.contains($0.id) }) {
                    claim.expenses[expenseIndex].claimant = name
                }
            }
            claim.invoiceLedgerEntries = entries
            let expenseIDs = Set(entries.filter { selectedRows.contains($0.id) }.map(\.expenseID))
            self.renameAttachments(expenseIDs, name)
        }
        selectedRows.removeAll()
    }
    private func deleteSelected() {
        let ids = selectedRows
        selectedRows.removeAll()
        for id in ids { files.removeLedgerRow(id) }
    }
    private var rows: [InvoiceLedgerRow] {
        claim.kind == .trip && tripRowsInTypeOrder ? claim.invoiceLedgerRowsInTypeOrder : claim.invoiceLedgerRows
    }
    private var rowCount: some View { Text("\(rows.count) 行 · \(claim.invoiceCount) 份发票").fixedSize() }
    private var invoiceTotal: some View { Text("票面合计 \(Money.format(claim.invoiceTotal))").fixedSize() }
    private var reimbursementTotal: some View { Text("报销单金额合计 \(Money.format(claim.ledgerReimbursementTotal))").foregroundStyle(Palette.accent).fixedSize() }
    private var ledgerHint: String {
        switch claim.kind {
        case .allowance: return "报销总额在基本信息中填写，与清单金额独立。"
        case .meal: return "报销总额按天数 × 单价计算，与清单金额独立。"
        case .trip: return "用途自动取出差事由，报销总额按费用明细计算。"
        }
    }
}

struct LedgerDateField: View {
    @Binding var value: String
    @State private var showingCalendar = false
    var body: some View {
        Button { showingCalendar.toggle() } label: {
            HStack(spacing: 6) {
                Text(value).monospacedDigit().fixedSize(horizontal: true, vertical: false)
                Image(systemName: "calendar").foregroundStyle(Palette.muted)
            }.font(.system(size: 11)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 27)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.ink.opacity(0.12)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help("选择日期（yyyy-MM-dd）")
            .accessibilityLabel("清单日期 \(value)")
            .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择日期").font(.system(size: 12, weight: .semibold))
                    DatePicker("日期", selection: Binding(get: { DayKey.date(value) ?? Date() }, set: {
                        value = DayKey.string($0)
                        showingCalendar = false
                    }), displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.graphical)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .environment(\.calendar, DayKey.calendar)
                }.padding(14)
            }
    }
}

private struct InvoiceLedgerCell: View {
    @Binding var claim: Claim
    var row: InvoiceLedgerRow
    var number: Int
    var column: ReimbursementColumn
    var files: ExpenseFileActions
    var batchMode: Bool
    var selected: Bool
    var toggleSelection: (Bool) -> Void
    private var names: [String] {
        var names = claim.travelerNames ?? []
        if let name = row.entry.claimant, !names.contains(name) { names.append(name) }
        return names
    }
    private func entryBinding<Value>(_ keyPath: WritableKeyPath<InvoiceLedgerEntry, Value>) -> Binding<Value> {
        Binding(get: { (claim.invoiceLedgerEntries?.first { $0.id == row.id } ?? row.entry)[keyPath: keyPath] }, set: { value in
            guard let index = claim.invoiceLedgerEntries?.firstIndex(where: { $0.id == row.id }) else { return }
            claim.invoiceLedgerEntries?[index][keyPath: keyPath] = value
        })
    }
    private func invoiceBinding<Value>(_ keyPath: WritableKeyPath<Attachment, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: {
            guard let invoice = claim.expenses.first(where: { $0.id == row.entry.expenseID })?.invoices.first(where: { $0.id == row.entry.invoiceID }) else { return fallback }
            return invoice[keyPath: keyPath]
        }, set: { value in
            guard let expense = claim.expenses.firstIndex(where: { $0.id == row.entry.expenseID }),
                  let invoice = claim.expenses[expense].invoices.firstIndex(where: { $0.id == row.entry.invoiceID }) else { return }
            claim.expenses[expense].invoices[invoice][keyPath: keyPath] = value
        })
    }
    var body: some View {
        Group {
            switch column.id {
            case "select":
                Toggle("选择第\(number)行", isOn: Binding(get: { selected }, set: toggleSelection))
                    .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("选择第\(number)行")
            case "sequence":
                if batchMode {
                    Toggle("选择第\(number)行", isOn: Binding(get: { selected }, set: toggleSelection))
                        .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("选择第\(number)行")
                } else {
                    Text("\(number)").monospacedDigit().foregroundStyle(Palette.muted).font(.system(size: 11))
                }
            case "date": LedgerDateField(value: entryBinding(\.date)).help(entryBinding(\.date).wrappedValue)
            case "person": TablePersonField(selection: entryBinding(\.claimant), names: names)
            case "number":
                TextField("发票号码", text: Binding(get: { invoiceBinding(\.number, fallback: nil).wrappedValue ?? "" },
                                                   set: { invoiceBinding(\.number, fallback: nil).wrappedValue = $0 }))
                    .monospacedDigit().help(row.invoice?.number ?? "未识别发票号码").accessibilityLabel("发票号码 \(number)")
            case "invoice":
                if let invoice = row.invoice { InvoiceFileCell(attachment: invoice, expenseID: row.entry.expenseID, actions: files) }
                else { Text("未上传").foregroundStyle(Palette.muted) }
            case "amount":
                if let invoice = row.invoice { AmountField(cents: invoiceBinding(\.amount, fallback: 0)).multilineTextAlignment(.center).help(Money.format(invoice.amount)).accessibilityLabel("发票金额 \(number)") }
                else { Text("—").foregroundStyle(Palette.muted) }
            case "reimbursement":
                AmountField(cents: entryBinding(\.reimbursementAmount)).multilineTextAlignment(.center).help(Money.format(row.entry.reimbursementAmount)).accessibilityLabel("报销单金额 \(number)")
            case "detail": TextField("填写明细", text: entryBinding(\.detail)).help(row.entry.detail).accessibilityLabel("明细 \(number)")
            case "purpose": Text(claim.ledgerPurpose.isEmpty ? "未填写" : claim.ledgerPurpose).foregroundStyle(claim.ledgerPurpose.isEmpty ? Palette.muted : Palette.ink)
                    .lineLimit(1).truncationMode(.tail).help(claim.ledgerPurpose)
            case "operations":
                HStack(spacing: 3) {
                    TableActionButton(title: "复制第\(number)行", icon: "doc.on.doc") { files.duplicateLedgerRow(row.id) }
                    TableActionButton(title: "上传第\(number)行发票", icon: "square.and.arrow.up") { files.replaceLedgerInvoice(row.id) }
                    TableActionButton(title: "删除第\(number)行", icon: "trash", destructive: true) { files.removeLedgerRow(row.id) }
                }
            default: EmptyView()
            }
        }.font(.system(size: 11)).textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
    }
}
