import SwiftUI
import AppKit

struct ClaimEditor: View {
    @EnvironmentObject private var store: ClaimStore
    @State private var draft: Claim
    @State private var selectedKind: ExpenseKind?
    @State private var saved = true
    @State private var deletingExpense: UUID?
    @State private var deletingCover: Attachment?
    private let source: Claim

    init(claim: Claim) {
        source = claim
        _draft = State(initialValue: claim.withPeopleAssigned.withDirectHotelTotals.withInvoiceLedger.withAllowanceTotal)
        _selectedKind = State(initialValue: claim.expenseGroups.first?.kind)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    metrics
                    if draft.kind == .allowance {
                        basicInfo
                    } else {
                        InfoCalendarRow {
                            basicInfo
                            Card(fillHeight: true) {
                                SectionLabel(title: "报销日期", subtitle: "点击多选，按下即可拖动扫选；可跨月")
                                CalendarPicker(selection: $draft.dates)
                            }.frame(width: 294)
                        }
                    }
                    if draft.kind == .trip {
                        peopleSection
                        tripLedgerSection
                        coverSection
                        expenseSection
                    } else {
                        InvoiceLedgerView(claim: $draft, export: { store.exportLedger(draft) }, files: fileActions, importInvoices: importLedgerInvoices)
                    }
                    HStack {
                        Image(systemName: "lock.shield").foregroundStyle(Palette.accent)
                        Text("修改自动保存至本机 · 发票金额自动识别，可手动修改 · 发票数量按 PDF 文件计")
                    }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.padding(26)
            }
        }
        .onChange(of: draft) { _, new in saved = store.save(new) }
        .onChange(of: source.title) { _, new in if draft.title != new { draft.title = new } }
        .onChange(of: source.status) { _, new in if draft.status != new { draft.status = new } }
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
                    Text("\(draft.kind.displayName)报销").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
                    Text("/").foregroundStyle(Palette.muted)
                    Text(draft.kind == .trip ? "费用工作台" : "报销清单").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                TextField("报销名称", text: $draft.title)
                    .font(.system(size: 23, weight: .semibold)).textFieldStyle(.plain)
                    .accessibilityLabel("报销标题").help("点击直接编辑报销名称，允许重名")
            }
            Spacer(minLength: 12)
            if saved { Label("已自动保存", systemImage: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.muted) }
            else { Button("重试保存") { saved = store.save(draft) }.foregroundStyle(.red) }
            Button { store.exportInvoices(draft) } label: { Label("导出发票", systemImage: "folder").padding(.vertical, 4) }
                .buttonStyle(ExportButtonStyle(color: .purple))
                .disabled(!saved || store.exporting || draft.expenses.flatMap(\.attachments).isEmpty)
            Button { store.export([draft]) } label: { Label("打印发票", systemImage: "printer").padding(.vertical, 4) }
                .buttonStyle(ExportButtonStyle(color: Palette.accent)).disabled(!saved || store.exporting)
        }.padding(.horizontal, 26).padding(.top, 42).padding(.bottom, 23)
    }

    private var metrics: some View {
        ReimbursementMetrics(days: draft.kind == .allowance ? nil : draft.reimbursementDayCount, total: draft.total, invoiceTotal: draft.invoiceTotal, invoiceCount: draft.invoiceCount)
    }
    private var basicInfo: some View {
        Card(fillHeight: true, spacing: draft.kind == .meal ? 10 : 16) {
            SectionLabel(title: "基本信息", subtitle: draft.kind == .allowance ? "报销人与用途" : "日期、报销人与费用自动关联")
            LabeledField(title: "\(draft.kind == .trip ? "出差人" : "报销人") · \(draft.travelerCount) 人") {
                PeopleTagInput(names: Binding(get: { draft.travelerNames ?? [] }, set: { draft.setTravelerNames($0) }),
                               rename: { draft.renameTraveler(from: $0, to: $1) })
            }
            HStack(alignment: .top, spacing: 16) {
                LabeledField(title: "部门") {
                    TextField("填写部门", text: Binding(get: { draft.department ?? "" }, set: { draft.department = $0 })).accessibilityLabel("部门")
                }.frame(maxWidth: draft.kind == .trip ? 240 : .infinity)
                if draft.kind == .trip {
                    LabeledField(title: "出差事由") {
                        TextField("填写出差事由", text: Binding(get: { draft.tripPurpose ?? "" }, set: { draft.tripPurpose = $0 })).accessibilityLabel("出差事由")
                    }.frame(maxWidth: .infinity)
                }
            }
            if draft.travelerNames == nil {
                Text("历史人数：\(draft.travelers) 人。填写姓名后，人数将按标签数量自动计算。")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if draft.kind == .allowance {
                HStack(spacing: 12) {
                    Text("报销总额（元）").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    AmountField(cents: Binding(get: { draft.total }, set: { draft.allowanceAmount = $0 }))
                        .frame(width: 160).accessibilityLabel("补贴报销总额")
                    Text("单独填写，与清单金额独立").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                }
            }
            if draft.kind == .meal {
                ForEach(draft.expenses) { expense in
                    if let index = draft.expenses.firstIndex(where: { $0.id == expense.id }) {
                        HStack(spacing: 10) {
                            Text(draft.expenses.count > 1 ? "每日单价 \(index + 1)" : "每日单价（元）")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                            AmountField(cents: Binding(get: { draft.expenses[index].unitPrice }, set: { draft.expenses[index].setDailyPrice($0) }))
                                .frame(width: 110)
                            Text("\(expense.days(in: draft)) 天 × \(Money.format(expense.unitPrice)) = \(Money.format(expense.total(in: draft)))")
                                .font(.system(size: 11)).foregroundStyle(Palette.accent).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if draft.expenses.isEmpty {
                    Button("设置每日单价") { draft.addExpense(draft.kind.categories[0], unitPrice: ExpenseDefaults.saved().price(for: draft.kind.categories[0])) }
                }
            }
            if draft.kind != .trip {
                HStack(spacing: 12) {
                    Text("用途").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    if draft.kind == .meal {
                        TextField("用途", text: .constant("餐补报销")).disabled(true)
                            .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 8).frame(height: 28)
                            .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.ink.opacity(0.08)))
                    } else {
                        TextField("填写用途，应用至清单每一行", text: Binding(get: { draft.reimbursementPurpose ?? "" }, set: { draft.reimbursementPurpose = $0 }))
                    }
                }
            }
            LabeledField(title: draft.kind == .trip ? "备注" : "备注 / 报销事由") {
                TextEditor(text: $draft.note).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(7).frame(minHeight: draft.kind == .meal ? 64 : 72, idealHeight: draft.kind == .meal ? 64 : 72, maxHeight: .infinity)
                    .background(.white, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.ink.opacity(0.10)))
                    .accessibilityLabel("备注 / 报销事由")
            }
            if draft.kind != .allowance {
                VStack(alignment: .leading, spacing: 7) {
                    Label("共 \(draft.dates.count) 个报销日", systemImage: "calendar").font(.system(size: 11)).foregroundStyle(Palette.accent)
                    Text(draft.dateSummary).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private var peopleSection: some View {
        Card {
            HStack {
                SectionLabel(title: "个人明细", subtitle: "每笔费用归属一位报销人；个人合计与整体总额同步")
                Spacer()
                Button("查看完整清单") { store.previewSummary(draft) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(draft.personBreakdowns) { person in
                        Button { store.previewSummary(draft, personID: person.id) } label: {
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
                SectionLabel(title: "费用明细", subtitle: "费用、发票与金额在同一清单核对和管理")
                Spacer()
                Menu {
                    if draft.kind == .trip {
                        Button("补助", systemImage: "banknote") { addExpense(.subsidy) }
                        Menu("交通") {
                            ForEach([ExpenseKind.train, .flight, .taxi]) { kind in Button(kind.displayName, systemImage: kind.icon) { addExpense(kind) } }
                        }
                        Button("住宿", systemImage: "bed.double") { addExpense(.hotel) }
                    } else {
                        ForEach(draft.kind.categories) { kind in Button(kind.displayName) { addExpense(kind) } }
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
                            Text("\(group.kind.displayName) · \(group.expenses.count) 笔").font(.system(size: 14, weight: .semibold))
                            Text("合计 \(Money.format(group.total(in: draft)))" + (group.kind.acceptsInvoices || group.invoiceCount > 0 ? " · \(group.invoiceCount) 份发票 · 票面合计 \(Money.format(group.invoiceTotal))" : " · 无需发票"))
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button { addExpense(group.kind) } label: {
                            Label("再加一笔", systemImage: "plus")
                        }
                    }.padding(.vertical, 4)
                    Card(spacing: 12) {
                        if group.kind.acceptsInvoices {
                            HStack {
                                Text("点击文件图标预览，点击名称改名").font(.system(size: 10)).foregroundStyle(Palette.muted)
                                Spacer()
                                Button { batchImport(group.kind) } label: {
                                    Label("导入", systemImage: "tray.and.arrow.down")
                                }.buttonStyle(ExportButtonStyle(color: Palette.accent))
                            }
                        }
                        TripExpenseListView(claim: $draft, kind: group.kind, remove: { deletingExpense = $0 }, files: fileActions)
                    }

                }
            }
        }
    }

    private var tripLedgerSection: some View {
        InvoiceLedgerView(claim: $draft,
                          export: { store.exportLedger(draft) },
                          files: fileActions,
                          showsImport: false)
    }

    private var coverSection: some View {
        Card {
            HStack {
                SectionLabel(title: "报销单", subtitle: "上传签字或审批后的报销单，打印时排在本记录发票上方")
                Spacer()
                Button { store.previewTripForm(draft) } label: { Label("预览报销单", systemImage: "doc.text.magnifyingglass") }
                    .accessibilityLabel("预览报销单")
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

    private var fileActions: ExpenseFileActions {
        ExpenseFileActions(upload: { upload(expenseID: $0, role: $1) }, open: open,
                           hover: { store.hoverAttachment($0, location: $1) },
                           rename: { rename($0, to: $1, expenseID: $2) },
                           remove: { removeAttachment($0, expenseID: $1) },
                           move: { attachment, source, destination in
            if let updated = store.moveItinerary(attachment, in: draft, from: source, to: destination) { draft = updated }
        }, duplicateExpense: { id in
            do { draft = try store.duplicateExpense(id, in: draft) } catch { store.errorMessage = error.localizedDescription }
        }, duplicateLedgerRow: { id in
            do { draft = try store.duplicateLedgerRow(id, in: draft) } catch { store.errorMessage = error.localizedDescription }
        }, removeLedgerRow: { id in
            if let updated = store.removeLedgerRow(id, in: draft) { draft = updated }
        }, replaceLedgerInvoice: { id in
            if let updated = store.chooseLedgerRowInvoice(id, in: draft) { draft = updated }
        })
    }

    private func batchImport(_ kind: ExpenseKind) {
        if let updated = store.chooseTripFiles(for: draft, kind: kind) { draft = updated; selectedKind = kind }
    }
    private func addExpense(_ kind: ExpenseKind) {
        draft.addExpense(kind, unitPrice: ExpenseDefaults.saved().price(for: kind))
        selectedKind = kind
    }
    private func importLedgerInvoices() {
        if draft.expenses.isEmpty { draft.addExpense(draft.kind.categories[0], unitPrice: 0) }
        guard let expenseID = draft.expenses.first?.id else { return }
        upload(expenseID: expenseID)
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

struct EditableAttachmentName: View {
    var attachment: Attachment
    var centered = false
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
                    Text(attachment.name).lineLimit(1).frame(maxWidth: centered ? nil : .infinity, alignment: centered ? .center : .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("修改附件名称：" + attachment.name)
            }
        }.font(.system(size: 12)).multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: centered ? nil : .infinity, alignment: centered ? .center : .leading)
            .help(attachment.name + "\n点击修改名称，回车或点击其他地方保存")
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

struct PlaceField: View {
    @Binding var text: String
    var placeholder: String
    private let places = ["北京", "上海", "广州", "深圳", "杭州", "南京", "苏州", "成都", "重庆", "武汉", "西安", "长沙", "郑州", "天津", "青岛", "厦门", "福州", "合肥", "济南", "昆明"]
    var body: some View {
        HStack(spacing: 3) {
            TextField(placeholder, text: $text)
            Menu {
                ForEach(places, id: \.self) { place in Button(place) { text = place } }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择常用城市，也可直接输入站点")
        }
    }
}
