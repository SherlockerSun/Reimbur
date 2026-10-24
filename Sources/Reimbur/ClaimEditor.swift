import SwiftUI
import AppKit

struct ClaimEditor: View {
    @EnvironmentObject private var store: ClaimStore
    @State private var draft: Claim
    @State private var selectedKind: ExpenseKind?
    @State private var saved = true
    @State private var showingPeople = false
    @State private var previewPersonID: String?
    @State private var deletingExpense: UUID?
    @State private var deletingCover: Attachment?
    private let source: Claim

    init(claim: Claim) {
        source = claim
        _draft = State(initialValue: claim.withPeopleAssigned.withDirectHotelTotals)
        _selectedKind = State(initialValue: claim.expenseGroups.first?.kind)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    metrics
                    InfoCalendarRow {
                        basicInfo
                        Card(fillHeight: true) {
                            SectionLabel(title: "报销日期", subtitle: "点击多选，按下即可拖动扫选；可跨月")
                            CalendarPicker(selection: $draft.dates)
                        }.frame(width: 294)
                    }
                    peopleSection
                    coverSection
                    expenseSection
                    HStack {
                        Image(systemName: "lock.shield").foregroundStyle(Palette.accent)
                        Text("修改自动保存至本机 · 发票金额自动识别，可手动修改 · 发票数量按 PDF 文件计")
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.padding(26)
            }
        }
        .onChange(of: draft) { _, new in saved = store.save(new) }
        .onChange(of: source.title) { _, new in if draft.title != new { draft.title = new } }
        .overlay {
            if showingPeople {
                DismissibleOverlay(close: { showingPeople = false }) {
                    ClaimTextPreview(claim: draft, initialPersonID: previewPersonID, close: { showingPeople = false })
                }
            }
        }
        .confirmationDialog("删除这项费用及其发票附件？", isPresented: Binding(get: { deletingExpense != nil }, set: { if !$0 { deletingExpense = nil } }), titleVisibility: .visible, presenting: deletingExpense) { id in
            Button("删除费用", role: .destructive) { removeExpense(id) }
            Button("取消", role: .cancel) { deletingExpense = nil }
        }
        .confirmationDialog("删除报销单 \(deletingCover?.name ?? "")？", isPresented: Binding(get: { deletingCover != nil }, set: { if !$0 { deletingCover = nil } }), titleVisibility: .visible, presenting: deletingCover) { attachment in
            Button("删除附件", role: .destructive) {
                removeAttachment(attachment, expenseID: nil)
                deletingCover = nil
            }
            Button("取消", role: .cancel) { deletingCover = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text("\(draft.kind.rawValue)报销").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
                    Text("/").foregroundStyle(Palette.muted)
                    Text("费用工作台").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                TextField("报销名称", text: $draft.title)
                    .font(.system(size: 23, weight: .semibold)).textFieldStyle(.plain)
                    .accessibilityLabel("报销标题").help("点击直接编辑报销名称，允许重名")
            }
            Spacer(minLength: 12)
            if saved { Label("已自动保存", systemImage: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            else { Button("重试保存") { saved = store.save(draft) }.foregroundStyle(.red) }
            Button { store.exportInvoices(draft) } label: { Label("导出发票", systemImage: "archivebox").padding(.vertical, 4) }
                .buttonStyle(ExportButtonStyle(color: .purple))
                .disabled(!saved || store.exporting || draft.expenses.flatMap(\.attachments).isEmpty)
            Button { store.export([draft]) } label: { Label("导出 Word", systemImage: "square.and.arrow.up").padding(.vertical, 4) }
                .buttonStyle(ExportButtonStyle(color: Palette.accent)).disabled(!saved || store.exporting)
        }.padding(.horizontal, 26).padding(.top, 42).padding(.bottom, 23)
    }

    private var metrics: some View {
        ReimbursementMetrics(days: draft.reimbursementDayCount, total: draft.total, invoiceTotal: draft.invoiceTotal, invoiceCount: draft.invoiceCount)
    }
    private var basicInfo: some View {
        Card(fillHeight: true) {
            SectionLabel(title: "基本信息", subtitle: "日期、报销人与费用自动关联")
            LabeledField(title: "\(draft.kind == .trip ? "出差人" : "报销人") · \(draft.travelerCount) 人") {
                PeopleTagInput(names: Binding(get: { draft.travelerNames ?? [] }, set: { draft.setTravelerNames($0) }),
                               rename: { draft.renameTraveler(from: $0, to: $1) })
            }
            if draft.travelerNames == nil {
                Text("历史人数：\(draft.travelers) 人。填写姓名后，人数将按标签数量自动计算。")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if draft.kind != .trip {
                Label("\(draft.kind.rawValue)按所选日期与单价计算", systemImage: draft.kind.icon)
                    .font(.system(size: 12)).foregroundStyle(Palette.accent)
            }
            LabeledField(title: "备注 / 报销事由") {
                TextEditor(text: $draft.note).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(7).frame(minHeight: 72, idealHeight: 72, maxHeight: .infinity)
                    .background(.white, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.ink.opacity(0.10)))
                    .accessibilityLabel("备注 / 报销事由")
            }
            VStack(alignment: .leading, spacing: 7) {
                Label("共 \(draft.dates.count) 个报销日", systemImage: "calendar").font(.system(size: 11)).foregroundStyle(Palette.accent)
                Text(draft.dateSummary).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
    }

    private var peopleSection: some View {
        Card {
            HStack {
                SectionLabel(title: "个人明细", subtitle: "每笔费用归属一位报销人；个人合计与整体总额同步")
                Spacer()
                Button("查看完整清单") { previewPersonID = nil; showingPeople = true }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(draft.personBreakdowns) { person in
                        Button { previewPersonID = person.id; showingPeople = true } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(person.name, systemImage: "person.crop.circle").font(.system(size: 12, weight: .medium))
                                Text(Money.format(person.total(in: draft))).font(.system(size: 17, weight: .semibold, design: .rounded))
                                Text("\(person.days(in: draft))天 · \(person.expenses.count)笔 · \(person.invoiceCount)份发票").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }.padding(13).frame(minWidth: 130, alignment: .leading)
                                .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(Palette.accent).help("查看\(person.name)的分类费用与合计")
                    }
                }
            }
        }
    }

    private var expenseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(title: "费用明细", subtitle: "\(draft.expenseGroups.count) 类 · \(draft.expenses.count) 笔费用 · 同类型合并汇总")
                Spacer()
                Menu {
                    if draft.kind == .trip {
                        Button("补助", systemImage: "banknote") { addExpense(.subsidy) }
                        Menu("交通") {
                            ForEach([ExpenseKind.train, .flight, .taxi]) { kind in Button(kind.rawValue, systemImage: kind.icon) { addExpense(kind) } }
                        }
                        Button("住宿", systemImage: "bed.double") { addExpense(.hotel) }
                    } else {
                        ForEach(draft.kind.categories) { kind in Button(kind.rawValue) { addExpense(kind) } }
                    }
                } label: { Label("添加费用", systemImage: "plus") }.fixedSize()
            }
            if draft.expenses.isEmpty {
                Card {
                    Label("还没有费用项目", systemImage: "list.bullet.rectangle").foregroundStyle(Palette.muted)
                    Text("点击“添加费用”，开始记录补助、交通或住宿。 ").font(.caption).foregroundStyle(Palette.muted)
                }
            } else {
                ExpenseGroupTabs(claim: $draft, selection: $selectedKind)
                if let group = draft.expenseGroups.first(where: { $0.kind == selectedKind }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(group.kind.rawValue) · \(group.expenses.count) 笔").font(.system(size: 14, weight: .semibold))
                            Text("合计 \(Money.format(group.total(in: draft)))" + (group.kind.acceptsInvoices || group.invoiceCount > 0 ? " · \(group.invoiceCount) 份发票 · 票面合计 \(Money.format(group.invoiceTotal))" : " · 无需发票"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button { addExpense(group.kind) } label: {
                            Label(group.kind == .subsidy && draft.travelerCount > 1 ? "再加一组补助" : "再加一笔\(group.kind.rawValue)", systemImage: "plus")
                        }
                    }.padding(.vertical, 4)
                    ForEach(group.expenses) { expense in
                        if let index = draft.expenses.firstIndex(where: { $0.id == expense.id }) {
                            expenseForm(index, number: (group.expenses.firstIndex(where: { $0.id == expense.id }) ?? 0) + 1)
                        }
                    }
                }
            }
        }
    }

    private func expenseForm(_ index: Int, number: Int) -> some View {
        let expense = draft.expenses[index]
        return Card {
            HStack {
                Label("\(expense.kind.rawValue) \(number)", systemImage: expense.kind.icon).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { deletingExpense = expense.id } label: { Image(systemName: "trash").foregroundStyle(Palette.muted) }.buttonStyle(.plain).help("删除此项费用")
            }
            HStack(spacing: 10) {
                Text("报销人").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                if (draft.travelerNames ?? []).isEmpty && expense.claimant == nil {
                    Text("先在基本信息中填写报销人，确认后自动选择第一人。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                } else {
                    Picker("报销人", selection: $draft.expenses[index].claimant) {
                        ForEach(draft.travelerNames ?? [], id: \.self) { name in Text(name).tag(Optional(name)) }
                        if let name = expense.claimant, !(draft.travelerNames ?? []).contains(name) {
                            Text("\(name)（已移出名单）").tag(Optional(name))
                        }
                    }.labelsHidden().fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
            if let name = expense.claimant, !(draft.travelerNames ?? []).contains(name) {
                Text("该人员已移出上方名单，现有费用仍保留；可重新选择报销人。")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if expense.kind.hasRoute {
                HStack(spacing: 12) {
                    LabeledField(title: "起始地") { PlaceField(text: $draft.expenses[index].origin, placeholder: "选择或输入起始地") }
                    Image(systemName: "arrow.right").foregroundStyle(Palette.muted).padding(.top, 20)
                    LabeledField(title: "目的地") { PlaceField(text: $draft.expenses[index].destination, placeholder: "选择或输入目的地") }
                }
            }
            HStack(alignment: .bottom, spacing: 20) {
                LabeledField(title: expense.kind.isTransport ? "本项交通总金额（元）" : expense.kind == .hotel ? "住宿总价（元）" : "每日单价（元）") {
                    AmountField(cents: Binding(get: {
                        expense.kind.isTransport || expense.kind == .hotel ? draft.expenses[index].total(in: draft) : draft.expenses[index].unitPrice
                    }, set: { value in
                        if expense.kind.isTransport || expense.kind == .hotel {
                            if draft.expenses[index].total(in: draft) != value { draft.expenses[index].setTotalAmount(value) }
                        } else if draft.expenses[index].unitPrice != value { draft.expenses[index].setDailyPrice(value) }
                    }))
                }.frame(maxWidth: 220)
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("本项合计").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Text(Money.format(expense.total(in: draft))).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Palette.accent)
                }
            }
            if !expense.kind.isTransport {
                HStack {
                    Text(expense.formula(in: draft)).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                    Spacer()
                    if expense.days(in: draft) == 0 && expense.kind != .hotel { Label("请选择日期", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange) }
                }.padding(12).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                Toggle(expense.kind == .hotel ? "单独选择入住日期（每个日期计一晚）" : "为这项费用单独选择日期", isOn: Binding(
                    get: { draft.expenses[index].dates != nil },
                    set: { draft.expenses[index].dates = $0 ? (expense.kind == .hotel ? expense.defaultStayDates(in: draft) : draft.dates) : nil }
                )).font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
                if expense.kind == .hotel && expense.dates == nil {
                    Text("默认 \(draft.dates.count) 天 \(expense.days(in: draft)) 晚；金额按住宿总价记录，支持从发票同步。")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                if expense.dates != nil {
                    CalendarPicker(selection: Binding(get: { draft.expenses[index].dates ?? [] }, set: { draft.expenses[index].dates = $0 })).frame(width: 270)
                    Text("本项仅使用单独选择的日期，不随上方报销日期变更。").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            LabeledField(title: "费用说明") { TextField("选填，例如车次、航班、酒店名称", text: $draft.expenses[index].note) }
            if expense.kind.acceptsInvoices || !expense.invoices.isEmpty {
                invoiceSection(index)
            } else {
                Label("出差补助无需发票，金额直接计入报销总额。", systemImage: "checkmark.seal")
                    .font(.system(size: 11)).foregroundStyle(Palette.accent)
            }
            if expense.kind == .taxi { itinerarySection(index) }
        }
    }

    private func itinerarySection(_ index: Int) -> some View {
        let expense = draft.expenses[index]
        return VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.6)
            HStack {
                SectionLabel(title: "打车行程单", subtitle: "\((expense.itineraries ?? []).count) 份 · 仅作为附件，不计发票数量、票面金额或差额")
                Spacer()
                Button { upload(expenseID: expense.id, role: .itinerary) } label: { Label("上传行程单", systemImage: "doc.badge.plus") }
            }
            ForEach(expense.itineraries ?? []) { attachment in
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(Palette.accent)
                    EditableAttachmentName(attachment: attachment) { rename(attachment, to: $0, expenseID: expense.id) }
                    Text("\(attachment.pageCount) 页").foregroundStyle(Palette.muted)
                    Button { open(attachment) } label: { Image(systemName: "eye") }.help("预览行程单")
                    Button { removeAttachment(attachment, expenseID: expense.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).help("立即删除行程单")
                }.font(.system(size: 12)).padding(12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
            if (expense.itineraries ?? []).isEmpty {
                Text("支持多选 PDF 或常见图片；与发票一起预览，并包含在“导出发票”和 Word 中。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder private func invoiceSection(_ index: Int) -> some View {
        let expense = draft.expenses[index]
            Divider().opacity(0.6)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(expense.kind.acceptsInvoices ? "发票附件" : "历史发票附件").font(.system(size: 13, weight: .semibold))
                    Text("\(expense.invoices.count) 份 PDF · \(expense.invoices.reduce(0) { $0 + $1.pageCount }) 页 · 合计 \(Money.format(expense.invoiceTotal))").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if expense.kind.acceptsInvoices {
                    Button { upload(expenseID: expense.id) } label: { Label("上传 PDF 发票", systemImage: "arrow.up.doc") }
                }
            }
            if expense.kind.acceptsInvoices && expense.invoices.isEmpty {
                Button { upload(expenseID: expense.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 24, weight: .light))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("添加这项费用的发票").font(.system(size: 12, weight: .medium))
                            Text("支持多选 PDF · 自动识别票面金额，可手动修改").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                    }.foregroundStyle(Palette.accent).padding(20).frame(maxWidth: .infinity)
                        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                }.buttonStyle(.plain)
            }
            if !expense.kind.acceptsInvoices {
                Text("出差补助无需发票。旧版附件保留在此，可预览或直接删除。").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            ForEach($draft.expenses[index].invoices) { $invoice in
                InvoiceRow(invoice: $invoice, open: { open(invoice) }, remove: { removeAttachment(invoice, expenseID: expense.id) },
                           rename: { rename(invoice, to: $0, expenseID: expense.id) }, amountChanged: { draft.expenses[index].synchronizeInvoiceTotal() })
            }
            HStack {
                Text("本项差额（费用 − 发票）").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Text(Money.format(expense.total(in: draft) - expense.invoiceTotal)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
    }

    private var coverSection: some View {
        Card {
            HStack {
                SectionLabel(title: "报销单", subtitle: "上传签字或审批后的报销单，导出时排在说明信息下方、发票上方")
                Spacer()
                Button { upload(expenseID: nil) } label: { Label("上传图片", systemImage: "photo.badge.plus") }
            }
            if draft.covers.isEmpty {
                Text("支持 PNG、JPEG、HEIC、TIFF、BMP、GIF；按上传顺序导出。").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            ForEach(draft.covers) { attachment in
                HStack(spacing: 12) {
                    Button { open(attachment) } label: {
                        HStack(spacing: 12) {
                            if let image = NSImage(contentsOf: store.url(for: attachment)) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 44, height: 52).background(Palette.canvas).clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(attachment.name).font(.system(size: 12)).lineLimit(1)
                                Text("报销单 · 点击快速预览").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button("预览") { open(attachment) }
                    Button { deletingCover = attachment } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func addExpense(_ kind: ExpenseKind) {
        draft.addExpense(kind, unitPrice: ExpenseDefaults.saved().price(for: kind))
        selectedKind = kind
    }
    private func upload(expenseID: UUID?, role: ExpenseAttachmentRole = .invoice) {
        if let updated = store.chooseFiles(for: draft, expenseID: expenseID, role: role) { draft = updated }
    }
    private func open(_ attachment: Attachment) {
        store.previewAttachment(attachment, in: draft)
    }
    private func rename(_ attachment: Attachment, to stem: String, expenseID: UUID) {
        do { draft = try store.renameAttachment(attachment, to: stem, in: draft, expenseID: expenseID) }
        catch { store.errorMessage = error.localizedDescription }
    }
    private func removeAttachment(_ attachment: Attachment, expenseID: UUID?) {
        if let updated = store.removeAttachment(attachment, from: draft, expenseID: expenseID) { draft = updated }
    }
    private func removeExpense(_ id: UUID) {
        guard let expense = draft.expenses.first(where: { $0.id == id }) else { return }
        var updated = draft
        updated.expenses.removeAll { $0.id == id }
        if store.save(updated) {
            draft = updated
            if !draft.expenses.contains(where: { $0.kind == selectedKind }) { selectedKind = draft.expenseGroups.first?.kind }
            for attachment in expense.attachments { store.discardFile(attachment) }
        }
        deletingExpense = nil
    }
}

private struct InvoiceRow: View {
    @Binding var invoice: Attachment
    var open: () -> Void
    var remove: () -> Void
    var rename: (String) -> Void
    var amountChanged: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Button(action: open) {
                    Image(systemName: "doc.richtext").font(.system(size: 23, weight: .light)).foregroundStyle(Palette.accent)
                }.buttonStyle(.plain).help("预览发票")
                VStack(alignment: .leading, spacing: 5) {
                    EditableAttachmentName(attachment: invoice, rename: rename)
                    Text("PDF · \(invoice.pageCount) 页 · 点击名称修改，点击图标预览").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            LabeledField(title: "票面金额（元）") { AmountField(cents: $invoice.amount) }.frame(width: 135)
            Button(action: open) { Image(systemName: "eye") }.help("在应用内预览 PDF")
            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Palette.muted).help("立即删除发票")
        }.padding(12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: invoice.amount) { _, _ in amountChanged() }
    }
}

struct EditableAttachmentName: View {
    var attachment: Attachment
    var rename: (String) -> Void
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool
    private var stem: String { URL(fileURLWithPath: attachment.name).deletingPathExtension().lastPathComponent }
    private var ext: String { URL(fileURLWithPath: attachment.name).pathExtension }
    var body: some View {
        Group {
            if editing {
                HStack(spacing: 0) {
                    TextField("附件名称", text: $text).textFieldStyle(.plain).focused($focused)
                        .onSubmit(commit).onChange(of: focused) { _, value in if !value && editing { commit() } }
                        .onExitCommand { editing = false; text = stem; focused = false }
                        .accessibilityLabel("附件名称")
                    if !ext.isEmpty { Text("." + ext).foregroundStyle(Palette.muted) }
                }
            } else {
                Button {
                    text = stem; editing = true
                    DispatchQueue.main.async { focused = true }
                } label: {
                    Text(attachment.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("修改附件名称：" + attachment.name)
            }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            .help("点击修改名称，回车或点击其他地方保存")
            .onAppear { text = stem }
            .onChange(of: attachment.name) { _, _ in text = stem }
            .background(OutsideClickObserver(enabled: editing, action: commit))
    }
    private func commit() {
        guard editing else { return }
        editing = false; focused = false
        if text != stem { rename(text) }
        text = stem
    }
}

private struct PlaceField: View {
    @Binding var text: String
    var placeholder: String
    private let places = ["北京", "上海", "广州", "深圳", "杭州", "南京", "苏州", "成都", "重庆", "武汉", "西安", "长沙", "郑州", "天津", "青岛", "厦门", "福州", "合肥", "济南", "昆明"]
    var body: some View {
        HStack(spacing: 3) {
            TextField(placeholder, text: $text)
            Menu {
                ForEach(places, id: \.self) { place in Button(place) { text = place } }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize().help("选择常用城市，也可直接输入站点")
        }
    }
}
