import SwiftUI
import Charts

struct PeriodPicker: View {
    var claims: [Claim]
    @Binding var period: ClaimPeriodFilter
    private var years: [Int] {
        Set(claims.map { DayKey.calendar.component(.year, from: ClaimPeriodFilter.date(for: $0)) } + [DayKey.calendar.component(.year, from: Date())]).sorted(by: >)
    }
    var body: some View {
        HStack(spacing: 6) {
            Picker("年份", selection: $period.year) {
                Text("所有年份").tag(0)
                ForEach(years, id: \.self) { Text("\(String($0)) 年").tag($0) }
            }.labelsHidden()
            Picker("月份", selection: $period.month) {
                Text("所有月份").tag(0)
                ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
            }.labelsHidden()
        }.font(.system(size: 11)).help("按首个报销日期筛选；尚未选日期的记录按创建日期筛选")
    }
}

struct DashboardView: View {
    var claims: [Claim]
    @Binding var period: ClaimPeriodFilter
    private var records: [Claim] { claims.filter(period.matches) }
    private var total: Int64 { records.reduce(0) { $0 + $1.total } }
    private var invoiceTotal: Int64 { records.reduce(0) { $0 + $1.invoiceTotal } }
    private var invoiceCount: Int { records.reduce(0) { $0 + $1.invoiceCount } }
    private struct MonthPoint: Identifiable {
        var date: Date
        var amount: Double
        var id: Date { date }
    }
    private var monthly: [MonthPoint] {
        let calendar = DayKey.calendar
        let latest = records.map(ClaimPeriodFilter.date).max() ?? Date()
        let end: Date
        if period.year != 0 { end = calendar.date(from: DateComponents(year: period.year, month: 12, day: 1))! }
        else { end = calendar.date(from: calendar.dateComponents([.year, .month], from: latest))! }
        return (0..<12).reversed().map { back in
            let date = calendar.date(byAdding: .month, value: -back, to: end)!
            let sameMonth = records.filter { calendar.isDate(ClaimPeriodFilter.date(for: $0), equalTo: date, toGranularity: .month) }
            return MonthPoint(date: date, amount: Double(sameMonth.reduce(Int64(0)) { $0 + $1.total }) / 100)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("报销概览").font(.system(size: 29, weight: .semibold))
                        Text("报销金额、发票与分类统计一目了然。").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    PeriodPicker(claims: claims, period: $period).frame(width: 250)
                }
                HStack(spacing: 14) {
                    Metric(title: "报销总额 · \(records.count) 条记录", value: Money.format(total), icon: "yensign.circle", emphasis: true)
                    Metric(title: "发票金额", value: Money.format(invoiceTotal), icon: "doc.text")
                    Metric(title: "发票数量", value: "\(invoiceCount) 份", icon: "square.stack")
                    Metric(title: "总额 − 发票金额", value: Money.format(total - invoiceTotal), icon: "arrow.left.arrow.right")
                }
                HStack(alignment: .top, spacing: 18) {
                    Card {
                        SectionLabel(title: "月度报销金额", subtitle: period.year == 0 ? "以最近一笔记录所在月为末月，展示近 12 个月" : "\(String(period.year)) 年 · 按月汇总")
                        Chart(monthly) { point in
                            BarMark(x: .value("月份", point.date, unit: .month), y: .value("金额（元）", point.amount))
                                .foregroundStyle(Palette.teal.gradient).cornerRadius(4)
                        }.chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits)) } }
                            .chartYAxisLabel("元").frame(height: 245)
                    }
                    Card {
                        SectionLabel(title: "报销类型分布", subtitle: "按报销金额统计 · 单位：元")
                        if total > 0 {
                            Chart(ClaimKind.allCases) { kind in
                                let value = records.filter { $0.kind == kind }.reduce(Int64(0)) { $0 + $1.total }
                                SectorMark(angle: .value("金额", Double(value) / 100), innerRadius: .ratio(0.62), angularInset: 3)
                                    .foregroundStyle(by: .value("类型", kind.rawValue))
                            }.chartForegroundStyleScale(["出差": Palette.teal, "餐补": Color.orange, "补助": Color.blue])
                                .frame(height: 245)
                        } else { Text("有报销金额后展示分布").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).frame(height: 245) }
                    }.frame(width: 300)
                }
                Card {
                    SectionLabel(title: "分类统计", subtitle: "时间筛选按首个报销日；未选日期按创建日")
                    ForEach(ClaimKind.allCases) { kind in
                        let items = records.filter { $0.kind == kind }
                        HStack {
                            Label("\(kind.rawValue)报销", systemImage: kind.icon).frame(width: 120, alignment: .leading)
                            Text("\(items.count) 条记录").foregroundStyle(Palette.muted)
                            Spacer()
                            Text(Money.format(items.reduce(0) { $0 + $1.total })).monospacedDigit().fontWeight(.medium)
                        }.font(.system(size: 13)).padding(.vertical, 7)
                    }
                }
            }.padding(32).padding(.top, 32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
