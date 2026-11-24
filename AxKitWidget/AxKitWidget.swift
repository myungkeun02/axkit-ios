import AxKitCore
import SwiftUI
import WidgetKit

/// Home-screen widget: how many 결재 are waiting and today's next plans. Reads the snapshot the app writes;
/// it never talks to the Mac itself.
struct Entry: TimelineEntry {
    var date: Date
    var snapshot: SharedPlace.Snapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .init(updatedAt: Date(), openCards: 2, firstCard: "원두 주문할까요?",
                                            events: [.init(title: "투자사 미팅", start: Date().addingTimeInterval(3600), allDay: false)]))
    }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Entry(date: Date(), snapshot: SharedPlace.snapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (WidgetKit.Timeline<Entry>) -> Void) {
        completion(WidgetKit.Timeline(entries: [Entry(date: Date(), snapshot: SharedPlace.snapshot())], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct AxKitWidgetView: View {
    var entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let s = entry.snapshot {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("결재").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(s.openCards)").font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(s.openCards > 0 ? Color.accentColor : .secondary)
                    Text(s.openCards > 0 ? (s.firstCard ?? "기다리는 중") : "기다리는 것 없음")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(family == .systemSmall ? 3 : 2)
                }
                .frame(maxWidth: family == .systemSmall ? .infinity : 110, alignment: .leading)
                if family != .systemSmall {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("오늘").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if s.events.isEmpty { Text("남은 일정이 없어요").font(.caption).foregroundStyle(.secondary) }
                        ForEach(s.events.prefix(3), id: \.self) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(e.allDay ? "종일" : e.start.map { Format.clock($0) } ?? "").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Text(e.title).font(.caption).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .widgetURL(URL(string: s.openCards > 0 ? "axkit://open/approvals" : "axkit://open/home"))
        } else {
            Text("ax-kit 앱을 열어 맥과 연결해 주세요").font(.caption).foregroundStyle(.secondary)
        }
    }
}

@main
struct AxKitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AxKitToday", provider: Provider()) { entry in
            AxKitWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("오늘과 결재")
        .description("기다리는 결재와 오늘 일정을 보여 줘요.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
