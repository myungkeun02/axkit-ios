import AxKitCore
import SwiftUI

/// §29 사람: cards for the people the owner told the assistant about. Every room reads them, so "대표님" is never
/// asked again. The owner can fix a card here; removing or merging is done by talking.
struct PeopleScreen: View {
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<[Person]> = .loading
    @State private var query = ""
    @State private var editing: Person?

    var body: some View {
        LoadableView(state: state, retry: load) { people in
            Page {
                if people.isEmpty {
                    EmptyStateView(icon: "person.crop.rectangle.stack", title: "아직 카드가 없어요", message: PeopleWords.empty)
                        .padding(.top, 40)
                } else {
                    let shown = people.filter { $0.matches(query) }
                    if shown.isEmpty {
                        Text("'\(query.trimmingCharacters(in: .whitespaces))'에 맞는 사람이 없어요.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    ForEach(shown) { person in
                        PersonCard(person: person) { editing = person }
                    }
                    Text(PeopleWords.deleteByTalking)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .refreshable { await load() }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "이름·회사·관계로 찾기")
        }
        .navigationTitle("사람")
        .task { await load() }
        .sheet(item: $editing) { person in
            PersonEditor(person: person) { saved in
                if case .loaded(var list) = state {
                    list.removeAll { $0.key == saved.key }
                    list.insert(saved, at: 0)
                    state = .loaded(list)
                }
                editing = nil
            }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.people().people) }
        catch { if case .loaded = state { return }; state = .failed(error.friendly) }
    }
}

private struct PersonCard: View {
    var person: Person
    var edit: () -> Void

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: person.name).font(.headline)
                        if !person.roleLine.isEmpty {
                            Text(verbatim: person.roleLine).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("고치기", action: edit)
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("\(person.name) 카드 고치기")
                }
                if !person.otherNames.isEmpty {
                    Text("이렇게도 불러요: \(person.otherNames.joined(separator: ", "))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let relation = person.relation {
                    Text(verbatim: relation).font(.subheadline)
                }
                if !person.noteLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(person.noteLines, id: \.self) { line in
                            Text(verbatim: line).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
                // One row when it fits, otherwise the "고침" time goes on its own line; nothing breaks mid-word.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { meta; Spacer(minLength: 0); edited }
                    VStack(alignment: .leading, spacing: 4) { HStack(spacing: 10) { meta }; edited }
                    VStack(alignment: .leading, spacing: 4) { meta; edited }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var meta: some View {
        if person.openCommitments > 0 {
            Text("열린 약속 \(person.openCommitments)개")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
                .fixedSize()
        }
        if person.emails > 0 { Text("메일 주소 \(person.emails)개").fixedSize() }
        if let seen = person.lastSeen { Text("마지막 연락 \(Format.relative(seen))").fixedSize() }
    }

    @ViewBuilder private var edited: some View {
        if let at = person.updatedAt { Text("\(Format.relative(at)) 고침").fixedSize() }
    }
}

private struct PersonEditor: View {
    var person: Person
    var saved: (Person) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var form: PersonForm
    @State private var busy = false
    @State private var problem: String?

    init(person: Person, saved: @escaping (Person) -> Void) {
        self.person = person
        self.saved = saved
        _form = State(initialValue: PersonForm(person))
    }

    private var body_: [String: String] { form.editBody(for: person) }
    private var changed: Bool { body_.count > 1 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("예: 대표", text: $form.title).labeled("직함·역할")
                    TextField("예: 에이컴퍼니", text: $form.company).labeled("회사")
                    TextField("예: 내가 일하는 회사 대표", text: $form.relation).labeled("나와의 관계")
                } footer: {
                    Text("비운 칸은 카드에서 지워져요.")
                }
                Section("메모") {
                    TextField("특징을 한 줄씩. 예: 결정이 빠름", text: $form.note, axis: .vertical)
                        .lineLimit(3...8)
                    Text("\(form.note.count)/\(PersonForm.limits.note)")
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let problem {
                    Section { Text(verbatim: problem).foregroundStyle(.red) }
                }
            }
            // §29 limits (직함 40 · 회사 60 · 관계 80 · 메모 400), the same as the Mac's.
            .onChange(of: form) { _, _ in form.clamp() }
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("저장") { Task { await save() } }.disabled(!changed)
                    }
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func save() async {
        guard changed, let client = model.client else { dismiss(); return }
        busy = true
        problem = nil
        do {
            let card = try await client.editPerson(body_)
            saved(card ?? form.applied(to: person))
        } catch {
            if case .refused(let message) = error as? APIError { problem = message }
            else { problem = (error as? APIError)?.friendlyMessage ?? "고치지 못했어요. 다시 해 주세요." }
            busy = false
        }
    }
}

private extension View {
    /// A small label above a form field.
    func labeled(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            self
        }
    }
}
