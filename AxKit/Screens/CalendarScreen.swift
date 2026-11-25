import AxKitCore
import SwiftUI

/// 캘린더: plans (blue) and what got done (green) on one month.
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @State private var month = Format.ymd(Date()).prefix(7).description
    @State private var selected = Format.ymd(Date())
    @State private var state: Loadable<CalendarView> = .loading
    @State private var adding = false

    private var canAdd: Bool { model.capabilities.view("calendar")?.actions?.contains("add") == true }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Format.seoul
        return c
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    LoadableView(state: state, retry: load) { data in
                        VStack(alignment: .leading, spacing: 16) {
                            grid(data)
                            legend(data)
                            if data.calendarsLimited == true {
                                Label(CalendarChoice.limitedNote, systemImage: "info.circle")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            dayDetail(data.day(selected), calendars: data.calendars ?? [])
                        }
                    }
                    .frame(minHeight: 300)
                }
                .padding(16)
            }
            .background(Theme.page)
            .recordingBarInset()
            .navigationTitle("캘린더")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("오늘로") { selected = Format.ymd(Date()); month = String(selected.prefix(7)) }
                        .disabled(selected == Format.ymd(Date()))
                }
                if canAdd {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { adding = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("일정 추가")
                    }
                }
            }
            .sheet(isPresented: $adding) {
                NewEventSheet(day: selected, calendars: state.value?.calendars) { added in
                    if let added { selected = added; month = String(added.prefix(7)) }
                    await load()
                }
            }
            .task(id: month) { await load() }
            .refreshable { await load() }
        }
    }

    private var monthTitle: String {
        let parts = month.split(separator: "-")
        return "\(parts.first ?? "")년 \(Int(parts.last ?? "") ?? 0)월"
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.action(.secondary, fullWidth: false, small: true)).accessibilityLabel("지난달")
            Spacer()
            Text(monthTitle).font(.title2.bold())
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.action(.secondary, fullWidth: false, small: true)).accessibilityLabel("다음 달")
        }
    }

    /// One calendar: plans (blue) and what got done (green). Several (§36): a color per calendar, then 한 일.
    private func legend(_ data: CalendarView) -> some View {
        let cals = CalendarChoice.legend(data.calendars)
        return FlowLayout(spacing: 12, lineSpacing: 6) {
            if cals.isEmpty {
                Label { Text("일정") } icon: { Circle().fill(Color.accentColor).frame(width: 8, height: 8) }
            }
            ForEach(cals) { cal in
                Label { Text(verbatim: CalendarChoice.label(cal, among: cals)).lineLimit(1) } icon: {
                    Circle().fill(CalendarTint.color(cal)).frame(width: 8, height: 8)
                }
            }
            Label { Text("한 일") } icon: { Circle().fill(.green).frame(width: 8, height: 8) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func grid(_ data: CalendarView) -> some View {
        let first = calendar.date(from: DateComponents(year: Int(month.prefix(4)), month: Int(month.suffix(2)), day: 1)) ?? Date()
        let lead = calendar.component(.weekday, from: first) - 1
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let cells: [Int?] = Array(repeating: nil, count: lead) + (1...count).map { Optional($0) }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(["일", "월", "화", "수", "목", "금", "토"].enumerated()), id: \.offset) { i, name in
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(i == 0 ? .red : .secondary)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    let ymd = "\(month)-\(String(format: "%02d", day))"
                    DayCell(day: day, isToday: ymd == Format.ymd(Date()), isSelected: ymd == selected, data: data.day(ymd),
                            calendars: data.calendars ?? [])
                        .onTapGesture { selected = ymd }
                } else {
                    Color.clear.frame(height: 48)
                }
            }
        }
        .padding(12)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    @ViewBuilder private func dayDetail(_ day: CalendarView.Day?, calendars: [CalendarView.CalendarInfo]) -> some View {
        let parts = selected.split(separator: "-")
        Text("\(Int(parts[safe: 1] ?? "") ?? 0)월 \(Int(parts[safe: 2] ?? "") ?? 0)일").font(.title3.bold())
        let events = day?.events ?? []
        let done = day?.done ?? []
        if events.isEmpty && done.isEmpty {
            Text("이날은 일정도, 한 일도 없어요.").foregroundStyle(.secondary)
        }
        if !events.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "일정")
                    ForEach(events) { e in
                        let cal = CalendarChoice.info(name: e.calendar, account: e.account, in: calendars)
                        HStack(alignment: .top, spacing: 12) {
                            Text(e.allDay == true ? "종일" : Format.clock(e.start)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.body.weight(.medium))
                                if let place = e.place { Text(place).font(.footnote).foregroundStyle(.secondary) }
                                if let name = e.calendar, !name.isEmpty {
                                    HStack(spacing: 5) {
                                        Circle().fill(cal.map(CalendarTint.color) ?? .secondary).frame(width: 7, height: 7)
                                        Text(verbatim: [name, e.account].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                            .lineLimit(1)
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        if !done.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "한 일")
                    ForEach(done) { d in
                        HStack(alignment: .top, spacing: 12) {
                            BotAvatar(icon: nil, name: d.bot?.name ?? "비서", size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.title).font(.body.weight(.medium))
                                Text("\(d.bot?.name ?? "비서") · \(Format.clock(d.at))").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func shift(_ months: Int) {
        let first = calendar.date(from: DateComponents(year: Int(month.prefix(4)), month: Int(month.suffix(2)), day: 1)) ?? Date()
        guard let next = calendar.date(byAdding: .month, value: months, to: first) else { return }
        month = String(Format.ymd(next).prefix(7))
        selected = month == String(Format.ymd(Date()).prefix(7)) ? Format.ymd(Date()) : "\(month)-01"
    }

    private func load() async {
        guard let client = model.client else { return }
        if state.value?.month != month { state = .loading }
        do { state = .loaded(try await client.view(CalendarView.self, "calendar", query: ["month": month])) }
        catch { state = .failed(error.friendly) }
    }
}

private struct DayCell: View {
    var day: Int
    var isToday: Bool
    var isSelected: Bool
    var data: CalendarView.Day?
    var calendars: [CalendarView.CalendarInfo] = []

    /// Up to three event dots: one per calendar that has something this day (one blue dot with a single calendar).
    private var eventColors: [Color] {
        guard let events = data?.events, !events.isEmpty else { return [] }
        guard calendars.count > 1 else { return [.accentColor] }
        var seen: [Color] = []
        for e in events {
            let c = CalendarChoice.info(name: e.calendar, account: e.account, in: calendars).map(CalendarTint.color) ?? .accentColor
            if !seen.contains(c) { seen.append(c) }
            if seen.count == 3 { break }
        }
        return seen
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("\(day)")
                .font(.callout.weight(isToday ? .bold : .regular))
                .frame(width: 32, height: 32)
                .foregroundStyle(isSelected ? .white : isToday ? Color.accentColor : .primary)
                .background(isSelected ? Color.accentColor : .clear, in: Circle())
            HStack(spacing: 3) {
                ForEach(Array(eventColors.enumerated()), id: \.offset) { _, c in Circle().fill(c).frame(width: 6, height: 6) }
                if !(data?.done.isEmpty ?? true) { Circle().fill(.green).frame(width: 6, height: 6) }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel("\(day)일, 일정 \(data?.events.count ?? 0)개, 한 일 \(data?.done.count ?? 0)개")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// 일정 추가: title, day, time (or all day), place. Saved to the Mac's calendar.
struct NewEventSheet: View {
    var day: String
    /// §36: the owner's calendars (nil from an older Mac). The picker shows only with two or more writable ones.
    var calendars: [CalendarView.CalendarInfo]? = nil
    var done: (String?) async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var allDay = false
    @State private var place = ""
    @State private var saving = false
    @State private var calendarId: String?

    private struct Ack: Decodable { var id: String?; var calendar: String? }

    private var choices: [CalendarView.CalendarInfo] { CalendarChoice.writable(calendars) }
    private var chosen: CalendarView.CalendarInfo? { choices.first { $0.id == calendarId } }

    var body: some View {
        NavigationStack {
            Page {
                Panel {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("무슨 일정인가요? (예: 치과)", text: $title)
                            .font(.title3.weight(.semibold))
                        Divider()
                        TextField("어디서 (안 적어도 돼요)", text: $place)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("하루 종일", isOn: $allDay).tint(.accentColor)
                        Divider()
                        DatePicker("시작", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                        if !allDay {
                            Divider()
                            DatePicker("끝", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                }
                if CalendarChoice.needsPicker(calendars) {
                    Panel {
                        HStack {
                            Text("캘린더")
                            Spacer()
                            Menu {
                                Picker("캘린더", selection: $calendarId) {
                                    ForEach(choices) { cal in
                                        Text(verbatim: CalendarChoice.label(cal, among: choices)).tag(Optional(cal.id))
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if let cal = chosen { Circle().fill(CalendarTint.color(cal)).frame(width: 10, height: 10) }
                                    Text(verbatim: chosen.map { CalendarChoice.label($0, among: choices) } ?? "기본 캘린더")
                                        .lineLimit(1)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.page, in: Capsule())
                            }
                            .accessibilityLabel("캘린더, \(chosen?.name ?? "기본 캘린더")")
                        }
                    }
                }
                Button {
                    Task { await save() }
                } label: {
                    HStack { Text("캘린더에 넣기"); if saving { Spacer(); ProgressView().tint(.white) } }
                }
                .buttonStyle(.action(.primary))
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
            .navigationTitle("일정 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            .onAppear {
                if calendarId == nil { calendarId = CalendarChoice.defaultChoice(calendars) }
                // Start on the selected day at the next whole hour, one hour long.
                var cal = Calendar(identifier: .gregorian); cal.timeZone = Format.seoul
                let hour = cal.component(.hour, from: Date()) + 1
                let parts = day.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3, let s = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: min(hour, 23))) {
                    start = s
                    end = s.addingTimeInterval(3600)
                }
            }
            .onChange(of: start) { _, s in if end <= s { end = s.addingTimeInterval(3600) } }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        guard let client = model.client else { return }
        saving = true
        defer { saving = false }
        let iso = ISO8601DateFormatter()
        var body: [String: Any] = ["title": title.trimmingCharacters(in: .whitespaces), "allDay": allDay,
                                   "start": allDay ? Format.ymd(start) : iso.string(from: start)]
        if !allDay { body["end"] = iso.string(from: end) }
        if !place.trimmingCharacters(in: .whitespaces).isEmpty { body["place"] = place.trimmingCharacters(in: .whitespaces) }
        // Only when there was a choice: with one calendar the Mac picks its main one, as before.
        if CalendarChoice.needsPicker(calendars), let calendarId { body["calendar"] = calendarId }
        do {
            let ack = try await client.viewAction(Ack.self, "calendar", "add", json: body)
            if let name = ack.calendar, !name.isEmpty { model.toast = "‘\(name)’ 캘린더에 넣었어요" } else { model.toast = "캘린더에 넣었어요" }
            await done(Format.ymd(start))
            dismiss()
        } catch {
            model.toast = error.friendly
        }
    }
}

/// §36: a calendar's color. The main calendar keeps the app's blue; green stays for 한 일.
enum CalendarTint {
    static let palette: [Color] = [.accentColor, .orange, .purple, .pink, .teal, .indigo, .brown, .red]
    static func color(_ cal: CalendarView.CalendarInfo) -> Color { palette[CalendarChoice.colorIndex(cal) % palette.count] }
}

/// Lays children left to right and wraps to the next line when they don't fit (the calendar legend).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + s.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .init(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
