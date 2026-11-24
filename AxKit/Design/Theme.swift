import AxKitCore
import UIKit
import SwiftUI

enum Theme {
    static let corner: CGFloat = 20
    /// The owner's own lines: a light tint, so the bots' words stay in front.
    static let ownerBubble = Color.accentColor.opacity(0.14)
    /// A team's work log line: quieter than a spoken line.
    static let statusBubble = Color(.tertiarySystemFill)
    static let assistantBubble = Color(.secondarySystemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let page = Color(.systemGroupedBackground)


    static func effectIcon(_ effects: [String]) -> String {
        if effects.contains("pay") { return "wonsign.circle.fill" }
        if effects.contains("send") { return "paperplane.circle.fill" }
        if effects.contains("delete") { return "trash.circle.fill" }
        if effects.contains("write") { return "pencil.circle.fill" }
        return "checkmark.circle.fill"
    }

    static func effectColor(_ effects: [String]) -> Color {
        if effects.contains("pay") { return .orange }
        if effects.contains("delete") { return .red }
        if effects.contains("send") { return .blue }
        return .green
    }
}

/// The one card used everywhere (결재 cards, calendar, documents, 더보기): white, rounded, on the grey page.
struct Panel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// A quiet label: small grey text, no fill.
struct Chip: View {
    var text: String
    var color: Color = .secondary
    var icon: String?
    var body: some View {
        Text(text).font(.caption).foregroundStyle(color == .secondary ? .secondary : color)
    }
}

/// Friendly empty or missing state, always in plain words.
struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Load-once-and-refresh state for a server view.
enum Loadable<T> {
    case loading
    case loaded(T)
    case failed(String)

    var value: T? { if case .loaded(let v) = self { v } else { nil } }
}

struct LoadableView<T, Content: View>: View {
    var state: Loadable<T>
    var retry: () async -> Void
    @ViewBuilder var content: (T) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView("불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                EmptyStateView(icon: "wifi.exclamationmark", title: "불러오지 못했어요", message: message)
                Button("다시 해 보기") { Task { await retry() } }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let value):
            content(value)
        }
    }
}

extension Error {
    var friendly: String { (self as? APIErrorFriendly)?.friendlyMessage ?? "잠깐 문제가 생겼어요. 다시 해 볼게요." }
}

protocol APIErrorFriendly { var friendlyMessage: String { get } }

/// A tap that only counts when the finger did not travel (a drag across it never fires). Used for every control that
/// sends something.
struct SafeTap: ViewModifier {
    var action: () -> Void
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

extension View {
    func safeTap(_ action: @escaping () -> Void) -> some View { modifier(SafeTap(action: action)) }
}

// MARK: shared building blocks (same look as the 결재 tab)

/// Grey page with cards stacked on it.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(16)
        }
        .background(Theme.page)
    }
}

/// The three button looks of the app: filled (suggested), light (other), light red (stop / no).
enum ActionKind {
    case primary, secondary, danger
    var foreground: Color {
        switch self {
        case .primary: .white
        case .secondary: .accentColor
        case .danger: .red
        }
    }
    var background: Color {
        switch self {
        case .primary: .accentColor
        case .secondary: Color.accentColor.opacity(0.12)
        case .danger: Color.red.opacity(0.1)
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    var kind: ActionKind = .secondary
    var fullWidth = true
    var small = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, small ? 12 : 16)
            .padding(.vertical, small ? 7 : 13)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: fullWidth ? .leading : .center)
            .background(kind.background, in: RoundedRectangle(cornerRadius: small ? 10 : 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : (enabled ? 1 : 0.45))
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static func action(_ kind: ActionKind = .secondary, fullWidth: Bool = true, small: Bool = false) -> ActionButtonStyle {
        ActionButtonStyle(kind: kind, fullWidth: fullWidth, small: small)
    }
}

/// Bold card heading with an optional grey line under it (same rhythm as 결재: context grey, question bold).
struct CardHeader: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One line inside a card: title, grey detail under it, something on the right.
struct CardRow<Trailing: View>: View {
    var title: String
    var detail: String? = nil
    var titleColor: Color = .primary
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(titleColor)
                if let detail, !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension CardRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil, titleColor: Color = .primary) {
        self.init(title: title, detail: detail, titleColor: titleColor) { EmptyView() }
    }
}

/// Lines inside one card, separated by hairlines.
struct CardList<Item: Identifiable, Row: View>: View {
    var items: [Item]
    @ViewBuilder var row: (Item) -> Row
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                row(item)
            }
        }
    }
}

/// A row that opens another screen: accent icon, title, chevron.
struct MenuRow: View {
    var icon: String
    var title: String
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.body).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// A label–value line for cards ("기종 · Mac mini").
struct KV: Identifiable { var id: String { title }; var title: String; var value: String; var color: Color = .secondary }

struct KVCard: View {
    var title: String
    var items: [KV]
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                CardHeader(title: title)
                CardList(items: items) { kv in
                    CardRow(title: kv.title) { Text(kv.value).foregroundStyle(kv.color).multilineTextAlignment(.trailing) }
                }
            }
        }
    }
}
