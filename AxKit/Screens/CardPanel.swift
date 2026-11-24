import AxKitCore
import SwiftUI

/// One 결재 card, kept bare: the question, the choices for how to do it, and a text box that is always there.
struct CardPanel: View {
    var card: CardEvent
    /// In the chat: a little tighter, same layout.
    var compact = false
    @Environment(AppModel.self) private var model
    @State private var busy: String?
    @State private var text = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    private var isOpen: Bool { model.timeline.isOpen(card.cardId) }
    private var closure: CardClosedEvent? { model.timeline.closure(of: card.cardId) }
    private var options: [CardOption] { card.options?.isEmpty == false ? card.options! : CardWords.defaultOptions(for: card) }
    /// `freeText: false` = the server wants buttons only (e.g. a tool-permission prompt).
    /// A card with an input window takes that instead of free text (§7.3).
    private var canWrite: Bool { card.freeText != false && card.form == nil }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Context first (who asked, what, when, why), then the question.
            // Context is never cut; only leftovers (metadata lines, prompt blocks, Discord marks) are cleaned away.
            let title = ChatText.cardTitle(summary: card.summary, note: card.note)
            let context = ChatText.clean(card.note ?? "")
            if !context.isEmpty, context != title {
                MarkdownText(context.hasPrefix(title + "\n") ? String(context.dropFirst(title.count + 1)) : context)
                    .font(compact ? .subheadline : .body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AttachedImages(attachments: card.attachments, imageUrl: card.imageUrl, height: compact ? 160 : 260)
            AttachedFiles(attachments: card.attachments)
            MarkdownText(title)
                .font(compact ? .headline : .title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if isOpen {
                answers
            } else {
                closedLine
            }
        }
        .padding(compact ? 14 : 18)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .opacity(isOpen ? 1 : 0.75)
    }

    // MARK: choices, one per line, then the text box (always shown)

    @ViewBuilder private var answers: some View {
        if let form = card.form {
            CardFormView(form: form, busy: busy == "form") { values in send("form", .form(id: form.id, fields: values)) }
                // A card asked again with a new form starts with fresh boxes, not the old answers.
                .id("\(form.id)#\(card.seq)")
        } else {
            choiceAnswers
        }
    }

    @ViewBuilder private var choiceAnswers: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(card.selects ?? []) { select in
                CardSelectView(select: select, busy: busy == "select:" + select.id) { values in
                    send("select:" + select.id, .select(id: select.id, values: values))
                }
            }
            // Servers that send only a menu (no buttons) shouldn't get the default approve/deny row.
            ForEach((card.selects?.isEmpty == false && card.options == nil) ? [] : options) { option in
                // A plain tap only: a drag (scrolling, the bot sheet) that crosses a choice must never pick it.
                HStack {
                    Text(option.label).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if busy == option.id { ProgressView().tint(foreground(option.tone)) }
                }
                .foregroundStyle(foreground(option.tone))
                .padding(.horizontal, 16)
                .padding(.vertical, compact ? 11 : 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background(option.tone), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .safeTap { choose(option) }
                .accessibilityLabel(option.label)
                .accessibilityHint(option.detail ?? "")
            }
            if let offer = card.remember {
                Toggle(isOn: $remember) { Text(offer.label).font(.subheadline) }
                    .toggleStyle(CheckToggle())
                    .padding(.top, 2)
            }
            if canWrite { inputRow(placeholder: "다른 지시를 직접 써 주세요") }
        }
    }

    /// Same three looks as every button in the app (see `ActionKind`).
    private func kind(_ tone: CardOption.Tone?) -> ActionKind {
        switch tone {
        case .primary: .primary
        case .danger: .danger
        default: .secondary
        }
    }
    private func foreground(_ tone: CardOption.Tone?) -> Color { kind(tone).foreground }
    private func background(_ tone: CardOption.Tone?) -> Color { kind(tone).background }

    private func inputRow(placeholder: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator)))
                .focused($focused)
            Button { TextComposition.finish { send("text", .text(String(trimmed.prefix(4000)))) } } label: {
                if busy == "text" { ProgressView().frame(width: 34, height: 34) } else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)) }
            }
            .disabled(trimmed.isEmpty || busy != nil)
            .accessibilityLabel("이 답 보내기")
        }
        .padding(.top, 4)
    }

    private var closedLine: some View {
        Label(CardWords.closedLabel(closure, expired: closure == nil), systemImage: closure?.state == "denied" ? "xmark.circle.fill" : "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func choose(_ option: CardOption) {
        guard busy == nil else { return }
        // 팀 구조 제안의 "앱에서 고칠게요" (fix-in-app; "edit" on the first server): nothing goes to the Mac — an answer
        // would close the proposal — the team-plan screen just opens, and the card stays until build or no.
        if card.isTeamPlan, CardEvent.teamPlanFixInApp.contains(option.id), model.capabilities.has("team-plan") {
            model.tab = .more
            model.moreRoute = "team-plan"
            return
        }
        send(option.id, CardWords.answer(for: option))
    }

    private func send(_ id: String, _ answer: CardAnswer) {
        busy = id
        Task {
            let done = await model.answer(card, answer, remember: remember && id != "text")
            busy = nil
            if done { text = ""; focused = false }
        }
    }
}

/// A plain check box: "앞으로는 알아서 하기".
struct CheckToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .font(.title3)
                .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
            configuration.label
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "선택됨" : "선택 안 됨")
    }
}

/// §7.3 input window: one field per row; `secret` fields are hidden (a P0 PIN). Required fields must be filled.
struct CardFormView: View {
    var form: CardForm
    var busy: Bool
    var submit: ([String: String]) -> Void
    @State private var values: [String: String] = [:]

    private var ready: Bool {
        form.fields.allSatisfy { f in f.required != true || !(values[f.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = form.title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label + (field.required == true ? "" : " (안 써도 돼요)")).font(.footnote).foregroundStyle(.secondary)
                    Group {
                        if field.secret == true {
                            SecureField(field.label, text: binding(field)).textContentType(.oneTimeCode).keyboardType(.numberPad)
                        } else {
                            TextField(field.label, text: binding(field), axis: field.multiline == true ? .vertical : .horizontal)
                                .lineLimit(field.multiline == true ? 3...8 : 1...1)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator)))
                }
            }
            Button {
                TextComposition.finish { submit(values.filter { !$0.value.isEmpty }) }
            } label: {
                HStack { Text("보내기"); if busy { Spacer(); ProgressView().tint(.white) } }
            }
            .buttonStyle(.action(.primary))
            .disabled(!ready || busy)
        }
        .onAppear { for f in form.fields where values[f.id] == nil { values[f.id] = f.value ?? "" } }
    }

    private func binding(_ field: CardForm.Field) -> Binding<String> {
        Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
    }
}

/// §7.3 menu: pick one (or up to `max`), then send.
struct CardSelectView: View {
    var select: CardSelect
    var busy: Bool
    var submit: ([String]) -> Void
    @State private var picked: [String] = []

    private var maxCount: Int { max(select.max ?? 1, 1) }
    private var minCount: Int { max(select.min ?? 1, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let placeholder = select.placeholder {
                Text(placeholder + (maxCount > 1 ? " (\(maxCount)개까지)" : "")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(select.choices) { choice in
                let on = picked.contains(choice.id)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: on ? (maxCount > 1 ? "checkmark.square.fill" : "largecircle.fill.circle") : (maxCount > 1 ? "square" : "circle"))
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.label).font(.body.weight(.semibold))
                        if let d = choice.description { Text(d).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(on ? ActionKind.secondary.background : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .safeTap { toggle(choice.id) }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Button {
                submit(picked)
            } label: {
                HStack { Text(maxCount > 1 ? "고른 \(picked.count)개 보내기" : "이걸로 할게요"); if busy { Spacer(); ProgressView().tint(.white) } }
            }
            .buttonStyle(.action(.primary))
            .disabled(picked.count < minCount || picked.isEmpty || busy)
        }
    }

    private func toggle(_ id: String) {
        if let i = picked.firstIndex(of: id) { picked.remove(at: i); return }
        if maxCount == 1 { picked = [id] } else if picked.count < maxCount { picked.append(id) }
    }
}
