import Foundation
import SwiftUI

enum RailCity {
    private static let aliases = [
        "上海虹桥": "上海", "上海松江": "上海", "安亭北": "上海", "安亭西": "上海",
        "北京丰台": "北京", "北京朝阳": "北京", "北京大兴": "北京", "大兴机场": "北京", "清河": "北京",
        "滨海": "天津", "滨海西": "天津", "滨海北": "天津", "塘沽": "天津", "天津滨海": "天津",
        "汉口": "武汉", "武昌": "武汉", "武汉东": "武汉",
        "广州白云": "广州", "广州新塘": "广州", "新塘": "广州",
        "深圳坪山": "深圳", "深圳机场": "深圳", "福田": "深圳", "平湖": "深圳",
        "杭州萧山": "杭州", "杭州余杭": "杭州", "余杭": "杭州", "临平南": "杭州", "富阳": "杭州",
        "庄桥": "宁波", "宁波庄桥": "宁波", "绍兴柯桥": "绍兴", "成都天府": "成都",
        "苏州园区": "苏州", "苏州新区": "苏州", "无锡新区": "无锡", "惠山": "无锡",
        "沙坪坝": "重庆", "重庆沙坪坝": "重庆"
    ]
    // Keep station recognition faithful to the ticket; normalize only the expense's city fields.
    static func name(_ station: String) -> String {
        var name = station.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["火车站", "高铁站", "铁路站", "站"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)); break
        }
        if let city = aliases[name] { return city }
        // Two-character city names such as 济南、淮南、淮北、台北 must retain their last character.
        if name.count > 2, !["黔东南", "黔西南"].contains(name), let last = name.last, "东西南北".contains(last) {
            name.removeLast()
        }
        return name
    }
}

enum RailMoment {
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = DayKey.calendar
        formatter.isLenient = false
        formatter.dateFormat = value.count == 10 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
    // Accept earlier timestamp values while presenting and ordering by calendar date only.
    static func dayKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let day = String(value.prefix(10))
        return date(day) == nil ? nil : day
    }
    static func ordered(_ expenses: [Expense]) -> [Expense] {
        expenses.enumerated().sorted { a, b in
            let x = dayKey(a.element.departureTime), y = dayKey(b.element.departureTime)
            if (x == nil) != (y == nil) { return x != nil }
            if let x, let y, x != y { return x < y }
            return a.offset < b.offset
        }.map(\.element)
    }
}

struct RailTimes: Hashable {
    var departure: String?
    var arrival: String?
    static func recognize(_ text: String) -> Self? {
        let text = text.folding(options: .widthInsensitive, locale: Locale(identifier: "zh_CN"))
        let datePattern = #"((?:19|20)\d{2})\s*[年/.-]\s*(\d{1,2})\s*[月/.-]\s*(\d{1,2})\s*日?"#
        let clockPattern = #"(\d{1,2})\s*[:时]\s*(\d{2})\s*分?"#
        func captures(_ pattern: String) -> [String?]? {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
        func normalized(_ values: [String?]?) -> String? {
            guard let values, values.count >= 3, let year = Int(values[0] ?? ""), let month = Int(values[1] ?? ""), let day = Int(values[2] ?? "") else { return nil }
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            guard RailMoment.date(date) != nil else { return nil }
            return date
        }
        var departure = normalized(captures(#"(?:出发时间|出发日期|发车时间|开车时间|乘车时间|乘车日期)[：:\s]*"# + datePattern))
        let arrival = normalized(captures(#"(?:到达时间|到达日期|抵达时间|抵达日期)[：:\s]*"# + datePattern))
        if departure == nil {
            // A ticket's explicit departure marker is safe; an invoice's issue date is not.
            departure = normalized(captures(datePattern + #"\s*"# + clockPattern + #"\s*(?:开|发车)"#))
        }
        return departure == nil && arrival == nil ? nil : Self(departure: departure, arrival: arrival)
    }
}

struct RailDateField: View {
    @Binding var value: String?
    var title: String
    var fallbackDate: Date
    @State private var showing = false
    @State private var draft = Date()
    var body: some View {
        Button {
            draft = RailMoment.date(value) ?? fallbackDate
            showing = true
        } label: {
            Group {
                if let day = RailMoment.dayKey(value) {
                    Text(day).monospacedDigit()
                } else { Label("选择日期", systemImage: "calendar").foregroundStyle(Palette.muted) }
            }.font(.system(size: 11)).frame(maxWidth: .infinity).frame(height: 28)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.ink.opacity(0.12)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title + "：" + (RailMoment.dayKey(value) ?? "未填写"))
            .help((RailMoment.dayKey(value) ?? "未填写") + "\n点击设置" + title)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    DatePicker("日期", selection: $draft, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                    HStack {
                        Button("清除") { value = nil; showing = false }
                        Spacer()
                        Button("确定") { value = DayKey.string(draft); showing = false }.keyboardShortcut(.defaultAction)
                    }
                }.padding(16).frame(width: 294).environment(\.locale, Locale(identifier: "zh_CN"))
            }
    }
}
