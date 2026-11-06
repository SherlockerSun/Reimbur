import SwiftUI

struct TripFormPreview: View {
    var claim: Claim
    @State private var selectedPerson: String?
    var close: () -> Void = {}
    @State private var command = FormPreviewCommand(action: .fit)
    private var people: [PersonBreakdown] { claim.personBreakdowns }
    private var person: PersonBreakdown? { people.first { $0.id == selectedPerson } ?? people.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("报销单预览").font(.system(size: 19, weight: .semibold))
                Spacer()
                PreviewIconButton(title: "缩小", icon: "minus.magnifyingglass") { command = FormPreviewCommand(action: .zoomOut) }
                PreviewIconButton(title: "放大", icon: "plus.magnifyingglass") { command = FormPreviewCommand(action: .zoomIn) }
                PreviewIconButton(title: "适应窗口", icon: "arrow.down.right.and.arrow.up.left") { command = FormPreviewCommand(action: .fit) }
            }.padding(.trailing, 38)
            if people.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(people) { item in
                            Button { selectedPerson = item.id } label: {
                                Text(item.name).font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 7)
                                    .foregroundStyle(person?.id == item.id ? Palette.accent : Palette.muted)
                                    .background(person?.id == item.id ? Palette.accent.opacity(0.10) : .white, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            InteractiveTripForm(data: TripFormData(claim: claim, person: person), command: command, close: close)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text("滚轮缩放 · 拖动空白处或按住空格平移 · 拖选文字后 ⌘C 复制")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(22)
    }
}

struct TripFormPaper: View {
    static let width: CGFloat = 1320
    var data: TripFormData
    static func height(for data: TripFormData) -> CGFloat { 360 + CGFloat(data.rowCount) * 42 + (data.claim.note.isEmpty ? 0 : 56) }
    struct Cell: Identifiable {
        var id: Int
        var rect: CGRect
        var text: String
        var size: CGFloat = 16
        var border = true
        var bold = false
    }
    var cells: [Cell] {
        var cells: [Cell] = []
        let left: CGFloat = 28, tableWidth = Self.width - 56
        func cell(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ text: String, size: CGFloat = 16, border: Bool = true, bold: Bool = false) {
            cells.append(Cell(id: cells.count, rect: CGRect(x: x, y: y, width: width, height: height), text: text, size: size, border: border, bold: bold))
        }
        cell(left, 20, tableWidth, 48, "出 差 旅 费 报 销 单", size: 32, border: false, bold: true)
        cell(left, 76, 820, 24, "行程日期：" + ClaimSummary.ranges(data.dates), size: 13, border: false)
        cell(left + 820, 76, tableWidth - 820, 24, "报销日期：" + DayKey.string(data.claim.updatedAt) + "    附单据 " + String(data.invoiceCount) + " 张", size: 13, border: false)
        cell(left, 106, 70, 44, "部门")
        cell(left + 70, 106, 220, 44, data.claim.department ?? "")
        cell(left + 290, 106, 80, 44, "出差人")
        cell(left + 370, 106, 200, 44, data.name)
        cell(left + 570, 106, 100, 44, "出差事由")
        cell(left + 670, 106, tableWidth - 670, 44, data.claim.tripPurpose ?? "")
        let weights: [CGFloat] = [30, 30, 58, 95, 30, 30, 58, 95, 52, 46, 76, 28, 28, 28, 42, 72, 28, 28, 28, 76, 110, 46, 76]
        let widths = weights.map { $0 / weights.reduce(0, +) * tableWidth }
        func x(_ index: Int) -> CGFloat { left + widths.prefix(index).reduce(0, +) }
        func span(_ from: Int, _ count: Int) -> CGFloat { widths.dropFirst(from).prefix(count).reduce(0, +) }
        let y: CGFloat = 150, header: CGFloat = 32, rowHeight: CGFloat = 42
        for (from, count, title) in [(0, 4, "出    发"), (4, 4, "到    达"), (11, 5, "途 中 补 贴"), (16, 4, "住 勤 费"), (20, 3, "其 他 费 用")] {
            cell(x(from), y, span(from, count), header, title)
        }
        for (index, title) in [(8, "交通\n工具"), (9, "单据\n张数"), (10, "车船费")] {
            cell(x(index), y, widths[index], header * 2, title)
        }
        let titles = ["月", "日", "时", "地点", "月", "日", "时", "地点", "", "", "", "早", "中", "晚", "夜间", "金额", "早", "中", "晚", "金额", "项目", "单据", "金额"]
        for index in titles.indices where ![8, 9, 10].contains(index) { cell(x(index), y + header, widths[index], header, titles[index]) }
        func amount(_ value: Int64) -> String { value == 0 ? "" : Money.input(value) }
        for row in 0..<data.rowCount {
            var values = Array(repeating: "", count: widths.count)
            if data.legs.indices.contains(row) {
                let leg = data.legs[row]
                let journey = TripFormData.momentParts(leg.departureTime, place: leg.originCity) + TripFormData.momentParts(leg.effectiveArrivalDate, place: leg.destinationCity)
                for index in 0..<8 { values[index] = journey[index] }
                values[8] = leg.kind.displayName
                values[9] = leg.invoices.isEmpty ? "" : String(leg.invoices.count)
                values[10] = amount(leg.total(in: data.claim))
            }
            values[15] = amount(data.subsidies[row, default: 0])
            if data.otherCosts.indices.contains(row) {
                let other = data.otherCosts[row]
                values[20] = other.title
                values[21] = other.count == 0 ? "" : String(other.count)
                values[22] = amount(other.amount)
            }
            for index in widths.indices { cell(x(index), y + header * 2 + CGFloat(row) * rowHeight, widths[index], rowHeight, values[index], size: index == 2 || index == 6 ? 13 : 16) }
        }
        let totalY = y + header * 2 + CGFloat(data.rowCount) * rowHeight
        cell(left, totalY, span(0, 9), 42, "合                         计", bold: true)
        for index in 9..<widths.count {
            var value = ""
            if index == 9 { value = String(data.legs.reduce(0) { $0 + $1.invoices.count }) }
            if index == 10 { value = amount(data.fare) }
            if index == 15 { value = amount(data.subsidy) }
            if index == 21 { value = String(data.otherCosts.reduce(0) { $0 + $1.count }) }
            if index == 22 { value = amount(data.otherTotal) }
            cell(x(index), totalY, widths[index], 42, value, bold: true)
        }
        let footer = totalY + 42
        cell(left, footer, 70, 58, "报销\n总额")
        cell(left + 70, footer, 100, 58, "人民币\n（大写）")
        cell(left + 170, footer, 535, 58, ChineseMoney.uppercase(data.total), size: 21)
        cell(left + 705, footer, 160, 58, "¥ " + Money.input(data.total), size: 23)
        cell(left + 865, footer, tableWidth - 865, 29, "预支旅费：________月________日", size: 14)
        cell(left + 865, footer + 29, (tableWidth - 865) / 2, 29, "补领不足：________", size: 14)
        cell(left + 865 + (tableWidth - 865) / 2, footer + 29, (tableWidth - 865) / 2, 29, "归还多余：________", size: 14)
        let signatureY = footer + 72
        cell(left + 20, signatureY, 300, 32, "主管：________________", border: false)
        cell(left + 430, signatureY, 300, 32, "审核：________________", border: false)
        cell(left + 840, signatureY, 380, 32, "报销人：" + data.name, border: false)
        if !data.claim.note.isEmpty { cell(left, signatureY + 40, tableWidth, 42, "备注：" + data.claim.note, size: 14, border: false) }
        return cells
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(cells) { cell in
                Text(cell.text).font(.custom("Songti SC", size: cell.size).weight(cell.bold ? .semibold : .regular))
                    .foregroundStyle(.black).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.65)
                    .padding(.horizontal, 4).frame(width: cell.rect.width, height: cell.rect.height)
                    .overlay { if cell.border { Rectangle().stroke(.black.opacity(0.85), lineWidth: 0.7) } }
                    .position(x: cell.rect.midX, y: cell.rect.midY)
            }
        }.frame(width: Self.width, height: Self.height(for: data))
    }
}
