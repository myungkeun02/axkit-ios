import Foundation

/// Buttons in the chat read like a conversation: the assistant asks in one bubble with its buttons inside, the
/// owner's pick shows as their own line, and buttons that can no longer be used are dimmed (not hidden).
public enum ChatChoices {
    /// How a line's buttons look.
    public enum State: Equatable, Sendable {
        /// The room's open question: tappable.
        case live
        /// Answered here (this id is marked) or the talk moved on (nil): dimmed, not tappable.
        case done(picked: String?)
    }

    /// `live`: the line whose buttons still work (`Timeline.openQuestion`), `picked`: what the owner chose on this line.
    public static func state(seq: Int, live: Int?, picked: String?) -> State {
        if let picked { return .done(picked: picked) }
        return live == seq ? .live : .done(picked: nil)
    }

    /// What the owner "said" by answering a 결재 in the chat, or nil while it is open (or closed with no word).
    public static func cardEcho(_ card: CardEvent, _ closure: CardClosedEvent?) -> String? {
        guard let closure else { return nil }
        if let answer = closure.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty { return answer }
        let options = card.options?.isEmpty == false ? card.options! : CardWords.defaultOptions(for: card)
        func pick(_ id: String, _ tone: CardOption.Tone) -> String? {
            (options.first { $0.id == id } ?? options.first { $0.tone == tone })?.label
        }
        switch closure.state {
        case "approved": return pick("decision:approve", .primary) ?? "네, 해 주세요"
        case "denied": return pick("decision:deny", .danger) ?? "아니요"
        case "edit": return options.first { $0.id == "decision:edit" }?.label ?? "고쳐서 다시"
        default: return nil
        }
    }

    /// The button a closed card was answered with (marked among the dimmed ones).
    public static func answeredOption(_ card: CardEvent, _ closure: CardClosedEvent?) -> String? {
        guard let echo = cardEcho(card, closure) else { return nil }
        let options = card.options?.isEmpty == false ? card.options! : CardWords.defaultOptions(for: card)
        return options.first { $0.label == echo }?.id
    }
}
