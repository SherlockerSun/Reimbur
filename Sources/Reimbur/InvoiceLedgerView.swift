import SwiftUI

// Shared widths keep headers and editable cells aligned; spare space goes to longer text.
enum InvoiceLedgerColumns {
    static let titles = ["序号", "日期", "姓名", "发票号码", "金额（元）", "报销单金额", "明细", "用途"]
    static let spacing: CGFloat = 8
    static func widths(for available: CGFloat) -> [CGFloat] {
        let minimum: [CGFloat] = [30, 122, 86, 184, 98, 104, 112, 90]
        let extra = max(0, available - minimum.reduce(0, +) - spacing * 7 - 20)
        let weights: [CGFloat] = [0, 0, 0.1, 0.2, 0.05, 0.05, 0.4, 0.2]
        return zip(minimum, weights).map { $0 + extra * $1 }
    }
}

struct InvoiceLedgerView: View {
    @Binding var claim: Claim
    var export: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .center) {
                SectionLabel(title: "报销清单", subtitle: "点击单元格编辑；发票在下方“发票附件”中导入和管理")
                Spacer(minLength: 12)
                Button(action: export) { Image(systemName: "square.and.arrow.up").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .help("导出 XLSX 报销清单").accessibilityLabel("导出 XLSX 报销清单")
            }
            if claim.invoiceLedgerRows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tablecells").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.accent)
                    Text("在下方导入发票后，自动生成清单").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
            } else {
                GeometryReader { geometry in
                    let widths = InvoiceLedgerColumns.widths(for: geometry.size.width)
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            HStack(spacing: InvoiceLedgerColumns.spacing) {
                                ForEach(InvoiceLedgerColumns.titles.indices, id: \.self) { index in
                                    Text(InvoiceLedgerColumns.titles[index])
                                        .frame(width: widths[index], alignment: index == 0 ? .center : (index == 4 || index == 5 ? .trailing : .leading))
                                }
                            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                                .padding(.horizontal, 10).frame(height: 38).background(Palette.canvas)
                            ForEach(Array(claim.invoiceLedgerRows.enumerated()), id: \.element.id) { index, row in
                                InvoiceLedgerTableRow(claim: $claim, row: row, number: index + 1, widths: widths)
                            }
                        }.padding(.bottom, 12)
                    }
                }.frame(height: CGFloat(38 + claim.invoiceLedgerRows.count * 48 + 12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    rowCount
                    Spacer(minLength: 0)
                    invoiceTotal
                    reimbursementTotal
                }
                VStack(alignment: .leading, spacing: 8) {
                    rowCount
                    invoiceTotal
                    reimbursementTotal
                }
            }.font(.system(size: 11)).monospacedDigit()
            HStack {
                Text("差额（报销总额 − 发票总额）").foregroundStyle(Palette.muted)
                Spacer()
                Text(Money.format(claim.difference)).fontWeight(.medium).monospacedDigit()
            }.font(.system(size: 11))
            Text(claim.kind == .allowance ? "报销总额在基本信息中填写，与清单金额独立。" : "报销总额按天数 × 单价计算，与清单金额独立。")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }
    private var rowCount: some View { Text("\(claim.invoiceLedgerRows.count) 行 · \(claim.invoiceCount) 份发票").fixedSize() }
    private var invoiceTotal: some View { Text("票面合计 \(Money.format(claim.invoiceTotal))").fixedSize() }
    private var reimbursementTotal: some View {
        Text("报销单金额合计 \(Money.format(claim.ledgerReimbursementTotal))").foregroundStyle(Palette.accent).fixedSize()
    }
}

struct LedgerDateField: View {
    @Binding var value: String
    @State private var showingCalendar = false
    var body: some View {
        Button { showingCalendar.toggle() } label: {
            HStack(spacing: 6) {
                Text(value).monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "calendar").foregroundStyle(Palette.muted)
            }.font(.system(size: 11)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 8).frame(height: 27)
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

private struct InvoiceLedgerTableRow: View {
    @Binding var claim: Claim
    var row: InvoiceLedgerRow
    var number: Int
    var widths: [CGFloat]
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
        HStack(spacing: InvoiceLedgerColumns.spacing) {
            Text("\(number)").foregroundStyle(Palette.muted).monospacedDigit().frame(width: widths[0])
            LedgerDateField(value: entryBinding(\.date)).frame(width: widths[1])
            Picker("报销人", selection: entryBinding(\.claimant)) {
                Text("未填写").tag(nil as String?)
                ForEach(names, id: \.self) { Text($0).tag(Optional($0)) }
            }.labelsHidden().frame(width: widths[2])
            TextField("发票号码", text: Binding(get: { invoiceBinding(\.number, fallback: nil).wrappedValue ?? "" },
                                                set: { invoiceBinding(\.number, fallback: nil).wrappedValue = $0 }))
                .monospacedDigit().frame(width: widths[3]).accessibilityLabel("发票号码 \(number)")
            Group {
                if row.invoice != nil { AmountField(cents: invoiceBinding(\.amount, fallback: 0)).accessibilityLabel("发票金额 \(number)") }
                else { Text("—").foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .trailing) }
            }.multilineTextAlignment(.trailing).frame(width: widths[4])
            AmountField(cents: entryBinding(\.reimbursementAmount)).multilineTextAlignment(.trailing)
                .frame(width: widths[5]).accessibilityLabel("报销单金额 \(number)")
            TextField("填写明细", text: entryBinding(\.detail)).frame(width: widths[6]).accessibilityLabel("明细 \(number)")
            Text(claim.ledgerPurpose.isEmpty ? "未填写" : claim.ledgerPurpose).foregroundStyle(claim.ledgerPurpose.isEmpty ? Palette.muted : Palette.ink)
                .lineLimit(1).truncationMode(.tail).help(claim.ledgerPurpose).frame(width: widths[7], alignment: .leading)
        }.font(.system(size: 11)).textFieldStyle(.roundedBorder)
            .padding(.horizontal, 10).frame(height: 48)
            .background(number.isMultiple(of: 2) ? Palette.canvas.opacity(0.55) : .white)
            .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}
