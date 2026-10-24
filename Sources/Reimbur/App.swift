import SwiftUI
import AppKit

#if !REIMBUR_VERIFY
@main struct ReimburApp: App {
    @StateObject private var store = ClaimStore(root: ProcessInfo.processInfo.environment["REIMBUR_DATA_DIR"].map { URL(fileURLWithPath: $0) })
    var body: some Scene {
        WindowGroup("Reimbur · 轻记报销") {
            WorkspaceView().environmentObject(store)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.light)
                .tint(Palette.teal)
        }
        .defaultSize(width: 1440, height: 940)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                ForEach(ClaimKind.allCases) { kind in
                    Button("新建\(kind.rawValue)报销") { _ = store.create(kind, defaults: ExpenseDefaults.saved()) }.disabled(!store.ready)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
#endif

struct WorkspaceView: View {
    @EnvironmentObject private var store: ClaimStore
    @AppStorage("recordsCollapsed") private var recordsCollapsed = false
    @AppStorage("startupPage") private var startupPage = "home"
    @State private var didAppear = false
    @State private var home = true
    @State private var filter: ClaimKind?
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var period = ClaimPeriodFilter()
    @State private var batch = false
    @State private var checked = Set<UUID>()
    @State private var deleting = Set<UUID>()
    @State private var renaming: UUID?
    @State private var newTitle = ""
    @State private var summary: Claim?
    private var filtered: [Claim] {
        store.claims.filter { (filter == nil || $0.kind == filter) && period.matches($0) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.note.localizedCaseInsensitiveContains(search) || ($0.travelerNames ?? []).contains { $0.localizedCaseInsensitiveContains(search) }) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            if store.showSettings {
                SettingsView()
            } else if home {
                DashboardView(claims: store.claims, period: $period)
            } else {
                recordPanel
                if let claim = store.claims.first(where: { $0.id == selectedID }) {
                    ClaimEditor(claim: claim).id(claim.id)
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "doc.text.below.ecg").font(.system(size: 48, weight: .light)).foregroundStyle(Palette.teal)
                        Text("选择一条报销记录，或新建开始记录").font(.system(size: 18))
                        newButton
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.32), value: recordsCollapsed)
        .background(Palette.canvas).foregroundStyle(Palette.ink).textFieldStyle(.roundedBorder)
        .overlay(alignment: .topTrailing) {
            if !home && !store.showSettings {
                recordToggle.padding(.trailing, 14).padding(.top, 5)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("Word 已导出", isPresented: Binding(get: { store.exportSuccess != nil }, set: { if !$0 { store.exportSuccess = nil } })) {
            Button("在 Finder 中显示") { if let url = store.exportSuccess { NSWorkspace.shared.activateFileViewerSelecting([url]) }; store.exportSuccess = nil }
            Button("完成", role: .cancel) { store.exportSuccess = nil }
        } message: { Text("已按说明信息、报销单、发票顺序排版。打印布局使用设置中的导出选项。") }
        .alert("重命名报销记录", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("报销名称", text: $newTitle)
            Button("保存") { if let id = renaming { store.rename(id, to: newTitle) }; renaming = nil }
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { renaming = nil }
        }
        .alert("删除 \(deleting.count) 条报销记录？", isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("删除记录", role: .destructive) {
                if store.delete(ids: deleting) { checked.subtract(deleting); if checked.isEmpty { batch = false } }
                deleting = []
            }
            Button("取消", role: .cancel) { deleting = [] }
        } message: { Text("所选记录、费用及其本地附件将一起删除。") }
        .overlay {
            if let request = store.preview {
                DismissibleOverlay(close: { store.preview = nil }) {
                    AttachmentPreview(request: request, close: { store.preview = nil }).id(request.id)
                }
            } else if let claim = summary {
                DismissibleOverlay(close: { summary = nil }) { ClaimTextPreview(claim: claim, close: { summary = nil }) }
            }
        }
        .overlay {
            if store.exporting {
                ZStack {
                    Color.black.opacity(0.25)
                    VStack(spacing: 18) { ProgressView(); Text("正在整理发票并生成 Word…") }
                        .padding(35).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .onAppear {
            if !didAppear {
                home = startupPage != "records"
                if !home { selectedID = filtered.first?.id }
                didAppear = true
            }
        }
        .onChange(of: store.claims.map(\.id)) { old, new in
            if let added = new.first(where: { !old.contains($0) }) {
                store.showSettings = false; home = false; selectedID = added; period = ClaimPeriodFilter(); search = ""
                if let kind = store.claims.first(where: { $0.id == added })?.kind, filter != nil && filter != kind { filter = kind }
            } else if !new.contains(selectedID ?? UUID()) { selectedID = filtered.first?.id }
            checked.formIntersection(new)
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            checked.formIntersection(ids)
            if !ids.contains(selectedID ?? UUID()) { selectedID = ids.first }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reimbur").font(.system(size: 22, weight: .semibold, design: .rounded))
                .frame(height: 28).padding(.bottom, 25)
            SidebarItem(title: "首页", icon: "house", selected: home && !store.showSettings) {
                store.showSettings = false; home = true; batch = false; checked = []
            }
            SidebarItem(title: "全部记录", icon: "tray.full", selected: !home && !store.showSettings && filter == nil, count: store.claims.count) { navigate(nil) }
            ForEach(ClaimKind.allCases) { kind in
                SidebarItem(title: "\(kind.rawValue)报销", icon: kind.icon, selected: !home && !store.showSettings && filter == kind,
                            count: store.claims.filter { $0.kind == kind }.count) { navigate(kind) }
            }
            Spacer()
            Text("轻记每一笔，安心每一天").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).padding(.bottom, 15)
            SidebarItem(title: "设置", icon: "gearshape", selected: store.showSettings) {
                store.showSettings = true; batch = false; checked = []
            }
        }.padding(20).padding(.top, 40).frame(width: 210)
            .background(Palette.ink).foregroundStyle(.white)
    }
    private var recordToggle: some View {
        Button {
            recordsCollapsed.toggle()
            batch = false; checked = []
        } label: { Image(systemName: "sidebar.left").frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Palette.muted)
            .help(recordsCollapsed ? "展开报销记录列表" : "收起报销记录列表")
            .accessibilityLabel(recordsCollapsed ? "展开报销记录列表" : "收起报销记录列表")
    }
    private var recordPanel: some View {
        HStack(spacing: 0) {
            recordList
            Divider().opacity(0.5)
        }
        .frame(width: 281)
        .frame(width: recordsCollapsed ? 0 : 281, alignment: .trailing)
        .clipped()
        .allowsHitTesting(!recordsCollapsed)
        .disabled(recordsCollapsed)
        .accessibilityHidden(recordsCollapsed)
    }
    private var recordList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(filter.map { "\($0.rawValue)报销" } ?? "全部记录").font(.system(size: 18, weight: .semibold))
                    Spacer(); newButton
                }
                HStack { Image(systemName: "magnifyingglass"); TextField("搜索名称、人员或备注", text: $search).textFieldStyle(.plain) }
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(9)
                    .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                PeriodPicker(claims: store.claims, period: $period)
                HStack {
                    Text("\(filtered.count) 条记录").foregroundStyle(Palette.muted)
                    Spacer()
                    Button(batch ? "取消" : "批量删除") { batch.toggle(); checked = [] }.buttonStyle(.plain)
                }.font(.system(size: 11))
                if batch {
                    HStack {
                        Button(checked.count == filtered.count && !filtered.isEmpty ? "取消全选" : "全选") {
                            checked = checked.count == filtered.count ? [] : Set(filtered.map(\.id))
                        }
                        Spacer()
                        Button("删除 \(checked.count) 条", role: .destructive) { deleting = checked }.disabled(checked.isEmpty)
                    }.font(.system(size: 11))
                }
            }.padding(18).padding(.top, 30)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { claim in row(claim) }
                    if filtered.isEmpty { Text("暂无匹配记录\n点击新建开始记录，或调整时间筛选").font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).padding(.top, 60) }
                }.padding(12)
            }
        }.frame(width: 280).background(.white)
    }
    @ViewBuilder private var newButton: some View {
        if let filter {
            Button { create(filter) } label: { Label("新建", systemImage: "plus.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Palette.teal).help("新建\(filter.rawValue)报销").disabled(!store.ready)
        } else {
            Menu {
                ForEach(ClaimKind.allCases) { kind in Button("新建\(kind.rawValue)报销", systemImage: kind.icon) { create(kind) } }
            } label: { Label("新建", systemImage: "plus.circle.fill").foregroundStyle(Palette.teal) }
                .menuStyle(.borderlessButton).fixedSize().disabled(!store.ready)
        }
    }
    private func row(_ claim: Claim) -> some View {
        ZStack {
            Button {
                if batch { if checked.contains(claim.id) { checked.remove(claim.id) } else { checked.insert(claim.id) } }
                else { selectedID = claim.id }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(claim.kind.rawValue, systemImage: claim.kind.icon).font(.system(size: 10)).foregroundStyle(Palette.teal)
                        Spacer()
                        Text(DayKey.string(ClaimPeriodFilter.date(for: claim))).font(.system(size: 9)).foregroundStyle(Palette.muted)
                    }
                    Text(claim.title.isEmpty ? "未命名报销" : claim.title).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(Money.format(claim.total)).font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("\(claim.invoiceCount) 份发票").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .padding(.leading, batch ? 24 : 0).padding(.trailing, 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack {
                if batch {
                    Toggle("选择记录", isOn: Binding(get: { checked.contains(claim.id) }, set: { if $0 { checked.insert(claim.id) } else { checked.remove(claim.id) } }))
                        .toggleStyle(.checkbox).labelsHidden().padding(.leading, 12)
                }
                Spacer()
                Button { summary = claim } label: { Image(systemName: "eye").frame(width: 32, height: 40) }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).help("预览报销清单").padding(.trailing, 6)
            }
        }.frame(maxWidth: .infinity)
            .background(selectedID == claim.id ? Palette.teal.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedID == claim.id ? Palette.teal.opacity(0.3) : Palette.ink.opacity(0.07)))
            .contentShape(Rectangle())
            .contextMenu {
                Button("预览清单", systemImage: "eye") { summary = claim }
                Button("复制清单", systemImage: "doc.on.doc") { copySummary(claim) }
                Divider()
                Button("重命名", systemImage: "pencil") { newTitle = claim.title; renaming = claim.id }
                Button("删除记录", systemImage: "trash", role: .destructive) { deleting = [claim.id] }
            }
    }
    private func navigate(_ kind: ClaimKind?) {
        store.showSettings = false; home = false; filter = kind; batch = false; checked = []
        if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
    }
    private func create(_ kind: ClaimKind) {
        if let id = store.create(kind, defaults: ExpenseDefaults.saved()) { store.showSettings = false; home = false; selectedID = id; search = ""; period = ClaimPeriodFilter(); batch = false; checked = [] }
    }
}

private struct SidebarItem: View {
    var title: String
    var icon: String
    var selected: Bool
    var count: Int? = nil
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
            }.padding(12).frame(maxWidth: .infinity)
                .background(.white.opacity(selected ? 0.16 : (hovering ? 0.09 : 0)), in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(title).accessibilityLabel(title)
    }
}

func copySummary(_ claim: Claim) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(ClaimSummary.render(claim), forType: .string)
}

struct ClaimTextPreview: View {
    var claim: Claim
    var close: () -> Void
    @State private var copied = false
    @State private var selectedPersonID: String
    init(claim: Claim, initialPersonID: String? = nil, close: @escaping () -> Void) {
        self.claim = claim.withPeopleAssigned
        self.close = close
        _selectedPersonID = State(initialValue: initialPersonID ?? "")
    }
    private var person: PersonBreakdown? { claim.personBreakdowns.first { $0.id == selectedPersonID } }
    private var text: String { person.map { ClaimSummary.renderPerson(claim, person: $0) } ?? ClaimSummary.renderOverview(claim) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("报销清单预览", systemImage: "doc.plaintext").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(copied ? "已复制" : (person == nil ? "复制总览" : "复制个人清单")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = true
                }
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }.padding(18).background(.white)
            Divider()
            HStack(spacing: 16) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            summaryTab("总览", id: "")
                            ForEach(claim.personBreakdowns) { person in summaryTab(person.name, id: person.id) }
                        }.padding(.vertical, 1)
                    }.frame(height: 36)
                        .onAppear { reader.scrollTo(selectedPersonID, anchor: .center) }
                        .onChange(of: selectedPersonID) { _, id in withAnimation { reader.scrollTo(id, anchor: .center) } }
                }
                VStack(alignment: .trailing, spacing: 5) {
                    Text(Money.format(person?.total(in: claim) ?? claim.total)).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(Palette.teal)
                    Text("\(person?.invoiceCount ?? claim.invoiceCount) 份发票 · 票面 \(Money.format(person?.invoiceTotal ?? claim.invoiceTotal))")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }.padding(.horizontal, 20).padding(.vertical, 14).background(.white)
            Divider()
            ScrollView {
                Text(text).font(.system(size: 13, design: .monospaced)).lineSpacing(7)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(26)
            }.id(selectedPersonID)
        }.background(Palette.canvas)
            .onChange(of: selectedPersonID) { _, _ in copied = false }
    }
    private func summaryTab(_ title: String, id: String) -> some View {
        Button { selectedPersonID = id } label: {
            Text(title).font(.system(size: 12, weight: selectedPersonID == id ? .semibold : .regular))
                .lineLimit(1).fixedSize().padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(selectedPersonID == id ? Palette.teal : Palette.muted)
                .background(selectedPersonID == id ? Palette.teal.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedPersonID == id ? Palette.teal.opacity(0.3) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).id(id)
            .accessibilityAddTraits(selectedPersonID == id ? .isSelected : [])
    }
}
