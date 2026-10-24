import SwiftUI
import AppKit

struct ExpenseDefaults: Equatable {
    var subsidy: Int64 = 0
    var meal: Int64 = 0
    var allowance: Int64 = 0
    var hotel: Int64 = 0
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        func amount(_ key: String) -> Int64 { max(0, min(Money.maximumCents, Int64(defaults.integer(forKey: key)))) }
        return Self(subsidy: amount("defaultSubsidy"), meal: amount("defaultMeal"), allowance: amount("defaultAllowance"), hotel: amount("defaultHotel"))
    }
    func price(for kind: ExpenseKind) -> Int64 {
        switch kind { case .subsidy: return subsidy; case .meal: return meal; case .allowance: return allowance; case .hotel: return hotel; default: return 0 }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: ClaimStore
    @AppStorage("startupPage") private var startupPage = "home"
    @AppStorage("defaultSubsidy") private var subsidy = 0
    @AppStorage("defaultMeal") private var meal = 0
    @AppStorage("defaultAllowance") private var allowance = 0
    @AppStorage("defaultHotel") private var hotel = 0
    @AppStorage("packLandscapeInvoices") private var packInvoices = true
    @State private var pathCopied = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("设置").font(.system(size: 29, weight: .semibold))
                    Text("偏好修改自动保存到这台 Mac。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Card {
                    SectionLabel(title: "通用", subtitle: "选择软件启动时显示的页面")
                    HStack {
                        Text("启动页面").font(.system(size: 13)); Spacer()
                        Picker("启动页面", selection: $startupPage) {
                            Text("首页").tag("home"); Text("全部记录").tag("records")
                        }.labelsHidden().frame(width: 180)
                    }
                }
                Card {
                    SectionLabel(title: "常用费用单价", subtitle: "单位：元；仅用于新建记录或添加费用，已有费用保持当前金额")
                    HStack(spacing: 24) {
                        price("出差补助 / 人天", value: $subsidy)
                        price("餐补 / 天", value: $meal)
                        price("补助 / 天", value: $allowance)
                        price("住宿 / 间晚", value: $hotel)
                    }
                }
                Card {
                    SectionLabel(title: "发票导出", subtitle: "Word 按说明信息 → 报销单 → 发票排列，保留 PDF 的全部页面")
                    Toggle("横向发票两张同页", isOn: $packInvoices).toggleStyle(.switch).controlSize(.small)
                    Text(packInvoices ? "较高或竖向的票据仍使用整页，保持打印可读性。" : "每张发票页面单独使用一页 A4 纸。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    HStack {
                        Text("共 \(store.claims.count) 条记录 · \(store.claims.reduce(0) { $0 + $1.invoiceCount }) 份发票")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button { store.export(store.claims) } label: { Label("导出全部发票", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent).disabled(store.claims.isEmpty || store.exporting || !store.ready)
                    }
                }
                Card {
                    SectionLabel(title: "数据与存储", subtitle: "SQLite 本地数据库；发票与报销单保留独立副本")
                    LabeledField(title: "数据存储路径") {
                        Text(store.root.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Label(store.ready ? "数据库运行正常" : "数据库不可用", systemImage: store.ready ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(store.ready ? Palette.teal : .orange)
                        Spacer()
                        Button(pathCopied ? "已复制路径" : "复制路径") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.root.path, forType: .string); pathCopied = true
                        }
                        Button("在 Finder 中打开") { NSWorkspace.shared.open(store.root) }
                    }
                    Text("备份时先退出软件，再复制整个数据文件夹；恢复时整体还原。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Card {
                    SectionLabel(title: "关于 Reimbur · 轻记报销", subtitle: "版本 \(version) · 原生 macOS 软件")
                    Text("支持 macOS 14 及以上 · SwiftUI / SQLite / PDFKit").font(.system(size: 12))
                    Text("数据仅保存在本机，修改自动保存。发票数量按上传的 PDF 文件计，票面金额由手动填写。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: 920).frame(maxWidth: .infinity, alignment: .leading).padding(32).padding(.top, 32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func price(_ title: String, value: Binding<Int>) -> some View {
        LabeledField(title: title) {
            AmountField(cents: Binding(get: { Int64(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }))
        }.frame(maxWidth: .infinity)
    }
}
