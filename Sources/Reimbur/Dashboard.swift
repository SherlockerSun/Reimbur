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
        }.font(.system(size: 11)).help("出差、餐补按首个报销日期筛选；补助及未选日期的记录按创建日期筛选")
    }
}

struct DashboardView: View {
    var claims: [Claim]
    @Binding var period: ClaimPeriodFilter
    @State private var hoveredMonth: Date?
    @State private var hoveredStatus: ClaimStatus?
    @State private var hoverLocation = CGPoint.zero
    @State private var hoverAvoidance = CGRect.zero
    @State private var coordinateID = UUID()
    private var records: [Claim] { claims.filter(period.matches) }
    private var total: Int64 { records.reduce(0) { $0 + $1.total } }
    private var invoiceTotal: Int64 { records.reduce(0) { $0 + $1.invoiceTotal } }
    private var invoiceCount: Int { records.reduce(0) { $0 + $1.invoiceCount } }
    private struct MonthPoint: Identifiable {
        var date: Date
        var records: [Claim]
        var amount: Double { Double(records.reduce(Int64(0)) { $0 + $1.total }) / 100 }
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
            return MonthPoint(date: date, records: sameMonth)
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
                ReimbursementMetrics(days: records.reduce(0) { $0 + $1.reimbursementDayCount },
                                     total: total, invoiceTotal: invoiceTotal, invoiceCount: invoiceCount)
                HStack(alignment: .top, spacing: 18) {
                    Card {
                        SectionLabel(title: "月度报销金额", subtitle: period.year == 0 ? "以最近一笔记录所在月为末月，展示近 12 个月" : "\(String(period.year)) 年 · 按月汇总")
                        monthlyChart
                    }
                    Card {
                        SectionLabel(title: "报销状态分布", subtitle: "按记录数统计")
                        if !records.isEmpty { statusChart }
                        else { Text("有报销记录后展示状态分布").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity).frame(height: 245) }
                    }.frame(width: 330)
                }
                Card {
                    SectionLabel(title: "分类统计", subtitle: "出差、餐补按首个报销日；补助及未选日期的记录按创建日")
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
            .coordinateSpace(name: coordinateID)
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    if let details = hoverDetails {
                        hoverDetail(title: details.title, items: details.items)
                            .frame(width: DashboardTooltipPlacement.size.width, height: DashboardTooltipPlacement.size.height)
                            .position(DashboardTooltipPlacement.position(pointer: hoverLocation, avoiding: hoverAvoidance, in: geometry.size))
                            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.9), value: hoverLocation)
                            .transition(.opacity)
                    }
                }.allowsHitTesting(false)
            }
            .onChange(of: period) { _, _ in hoveredMonth = nil; hoveredStatus = nil }
    }
    private var monthlyChart: some View {
        Chart(monthly) { point in
            BarMark(x: .value("月份", point.date, unit: .month), y: .value("金额（元）", point.amount))
                .foregroundStyle(Palette.accent.gradient).cornerRadius(4)
                .opacity(hoveredMonth == nil || hoveredMonth == point.date ? 1 : 0.4)
        }
        .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.defaultDigits)) } }
        .chartYAxisLabel("元")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame, geometry[frame].contains(location),
                                      let date = proxy.value(atX: location.x - geometry[frame].minX, as: Date.self) else { hoveredMonth = nil; return }
                                hoveredMonth = monthly.first { DayKey.calendar.isDate($0.date, equalTo: date, toGranularity: .month) }?.date
                                hoveredStatus = nil
                                let origin = geometry.frame(in: .named(coordinateID)).origin
                                hoverLocation = CGPoint(x: origin.x + location.x, y: origin.y + location.y)
                                if let selected = hoveredMonth, let x = proxy.position(forX: selected) {
                                    let plot = geometry[frame]
                                    let width = plot.width / 12
                                    hoverAvoidance = CGRect(x: origin.x + plot.minX + x - width / 2,
                                                            y: origin.y + plot.minY, width: width * 2, height: plot.height)
                                }
                            case .ended: hoveredMonth = nil
                            }
                        }
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: hoveredMonth)
        .frame(height: 245)
    }

    private var statusChart: some View {
        VStack(spacing: 10) {
        Chart(ClaimStatusSummary.all(in: claims, period: period)) { summary in
            SectorMark(angle: .value("记录数", summary.records.count), innerRadius: .ratio(0.62),
                       outerRadius: .ratio(hoveredStatus == summary.status ? 1 : 0.94), angularInset: 3)
                .foregroundStyle(summary.status.color)
                .opacity(hoveredStatus == nil || hoveredStatus == summary.status ? 1 : 0.4)
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    VStack(spacing: 4) {
                        Text("\(records.count)").font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text("条报销记录").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.position(x: geometry[frame].midX, y: geometry[frame].midY)
                }
            }.allowsHitTesting(false)
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { hoveredStatus = nil; return }
                                hoveredMonth = nil
                                let origin = geometry.frame(in: .named(coordinateID)).origin
                                hoverLocation = CGPoint(x: origin.x + location.x, y: origin.y + location.y)
                                hoverAvoidance = geometry[frame].offsetBy(dx: origin.x, dy: origin.y)
                                hoveredStatus = DashboardChartHitTesting.status(at: location, plot: geometry[frame], counts: ClaimStatus.allCases.map { status in
                                    records.filter { $0.status == status }.count
                                })
                            case .ended: hoveredStatus = nil
                            }
                        }
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hoveredStatus)
        HStack(spacing: 12) {
            ForEach(ClaimStatusSummary.all(in: claims, period: period)) { summary in
                HStack(spacing: 4) {
                    Circle().fill(summary.status.color).frame(width: 6, height: 6)
                    Text("\(summary.status.rawValue) \(summary.records.count)")
                }.font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.fixedSize()
        }.frame(height: 245)
    }

    private var hoverDetails: (title: String, items: [Claim])? {
        if let point = monthly.first(where: { $0.date == hoveredMonth }) {
            return (point.date.formatted(.dateTime.year().month().locale(Locale(identifier: "zh_CN"))), point.records)
        }
        if let status = hoveredStatus { return (status.rawValue, records.filter { $0.status == status }) }
        return nil
    }

    private func hoverDetail(title: String, items: [Claim]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("报销总额  \(Money.format(items.reduce(0) { $0 + $1.total }))")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
            Text("\(items.count) 条记录" + (items.allSatisfy { $0.kind == .allowance } ? "" : " · \(items.reduce(0) { $0 + $1.reimbursementDayCount }) 天") + " · \(items.reduce(0) { $0 + $1.invoiceCount }) 份发票")
            Text("发票总额  \(Money.format(items.reduce(0) { $0 + $1.invoiceTotal }))")
        }.font(.system(size: 11)).foregroundStyle(Palette.ink)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.accent.opacity(0.2)))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
    }

}


// SectorMark starts at twelve o'clock and proceeds clockwise; ignore the hole and legend.
enum DashboardChartHitTesting {
    static func status(at point: CGPoint, plot: CGRect, counts: [Int]) -> ClaimStatus? {
        let radius = min(plot.width, plot.height) / 2
        let dx = point.x - plot.midX, dy = point.y - plot.midY
        guard radius > 0, hypot(dx, dy) >= radius * 0.62, hypot(dx, dy) <= radius else { return nil }
        let total = counts.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return nil }
        let angle = (atan2(dx, -dy) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let value = angle / (2 * .pi) * Double(total)
        var cumulative = 0
        for (status, count) in zip(ClaimStatus.allCases, counts) where count > 0 {
            cumulative += count
            if value < Double(cumulative) { return status }
        }
        return nil
    }
    static func kind(at point: CGPoint, plot: CGRect, values: [Int64]) -> ClaimKind? {
        let radius = min(plot.width, plot.height) / 2
        guard radius > 0 else { return nil }
        let dx = point.x - plot.midX, dy = point.y - plot.midY
        let distance = hypot(dx, dy)
        guard distance >= radius * 0.62, distance <= radius else { return nil }
        let total = values.reduce(Int64(0)) { $0 + max(0, $1) }
        guard total > 0 else { return nil }
        let angle = (atan2(dx, -dy) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        let amount = angle / (2 * .pi) * Double(total)
        var cumulative: Double = 0
        for (kind, value) in zip(ClaimKind.allCases, values) where value > 0 {
            cumulative += Double(value)
            if amount < cumulative { return kind }
        }
        return nil
    }
}


enum DashboardTooltipPlacement {
    static let size = CGSize(width: 232, height: 112)
    static func position(pointer: CGPoint, avoiding mark: CGRect, in bounds: CGSize) -> CGPoint {
        let padding: CGFloat = 10, gap: CGFloat = 16
        func clamped(_ rect: CGRect) -> CGRect {
            CGRect(x: min(max(padding, rect.minX), max(padding, bounds.width - size.width - padding)),
                   y: min(max(padding, rect.minY), max(padding, bounds.height - size.height - padding)),
                   width: size.width, height: size.height)
        }
        let preferred = clamped(CGRect(origin: CGPoint(x: pointer.x + gap, y: pointer.y + gap), size: size))
        if !preferred.intersects(mark.insetBy(dx: -padding, dy: -padding)) { return CGPoint(x: preferred.midX, y: preferred.midY) }
        let candidates = [
            CGRect(x: mark.maxX + gap, y: pointer.y - size.height / 2, width: size.width, height: size.height),
            CGRect(x: mark.minX - gap - size.width, y: pointer.y - size.height / 2, width: size.width, height: size.height),
            CGRect(x: pointer.x - size.width / 2, y: mark.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: pointer.x - size.width / 2, y: mark.maxY + gap, width: size.width, height: size.height)
        ].map(clamped).filter { !$0.intersects(mark.insetBy(dx: -padding, dy: -padding)) }
        let rect = candidates.min { a, b in
            hypot(a.midX - pointer.x, a.midY - pointer.y) < hypot(b.midX - pointer.x, b.midY - pointer.y)
        } ?? preferred
        return CGPoint(x: rect.midX, y: rect.midY)
    }
}
