import AxKitCore
import SwiftUI

/// Which document, and which view on the Mac answers for it (`knowledge` documents and `docgraph` notes have
/// different ids, so a document always opens through the view it came from).
struct DocRoute: Hashable { var id: String; var source: String }

/// 문서: a plain tree (분야 → 문서) with the newest on top, and a search that reads titles, 분야, summaries and the
/// documents themselves — spaces ignored, part of a word or first sounds ("ㄱㅈ") enough, hits highlighted.
struct DocsView: View {
    @Environment(AppModel.self) private var model
    @State private var graph: Loadable<DocGraphView> = .loading
    @State private var knowledge: Loadable<KnowledgeView> = .loading
    @State private var path: [DocRoute] = []
    @State private var query = ""
    @State private var searching = false

    private var hasGraph: Bool { model.capabilities.hasView("docgraph") }
    private var hasKnowledge: Bool { model.capabilities.hasView("knowledge") }

    /// Built when a list arrives, not on every keystroke in the search box (900+ documents).
    @State private var shelf = DocShelf(sections: [])

    private func rebuildShelf() {
        var sections: [DocShelf.Section] = []
        if case .loaded(let k) = knowledge { sections += DocShelf(k).sections }
        if case .loaded(let g) = graph { sections += DocShelf(g).sections }
        shelf = DocShelf(sections: sections)
    }

    private var isLoading: Bool {
        (hasKnowledge && { if case .loading = knowledge { true } else { false } }()) || (hasGraph && { if case .loading = graph { true } else { false } }())
    }

    private var failure: String? {
        if case .failed(let m) = knowledge { return m }
        if case .failed(let m) = graph { return m }
        return nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !hasGraph && !hasKnowledge && !model.capabilities.views.isEmpty {
                    EmptyStateView(icon: "doc.text.magnifyingglass", title: "맥에 아직 문서가 없어요",
                                   message: "맥의 비서를 새 버전으로 올리면 여기에 문서가 보여요.")
                } else if shelf.sections.isEmpty && isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shelf.sections.isEmpty, let failure {
                    EmptyStateView(icon: "exclamationmark.triangle", title: "문서를 불러오지 못했어요", message: failure)
                } else {
                    DocShelfView(shelf: shelf, query: query)
                }
            }
            .background(Theme.page)
            .recordingBarInset()
            .navigationTitle("문서")
            .searchable(text: $query, isPresented: $searching, prompt: "제목·내용·분야로 찾기")
            .navigationDestination(for: DocRoute.self) { DocumentScreen(id: $0.id, source: $0.source, highlight: query) }
            .task { await loadAll() }
            .refreshable { await loadAll() }
        }
        .onChange(of: model.docQuery, initial: true) { _, q in
            guard let q else { return }
            model.docQuery = nil
            path = []
            query = q
            searching = !q.isEmpty
        }
        .onChange(of: model.docRoute, initial: true) { _, id in
            guard let id else { return }
            model.docRoute = nil
            let source = shelf.sections.flatMap(\.docs).first { $0.id == id }?.source ?? (hasKnowledge && id.contains("/") ? "knowledge" : "docgraph")
            path = [DocRoute(id: id, source: source)]
        }
    }

    private func loadAll() async {
        async let a: Void = loadKnowledge()
        async let b: Void = loadGraph()
        _ = await (a, b)
    }

    private func loadGraph() async {
        guard hasGraph, let client = model.client else { return }
        do { graph = .loaded(try await client.view(DocGraphView.self, "docgraph")) } catch { graph = .failed(error.friendly) }
        rebuildShelf()
    }

    private func loadKnowledge() async {
        guard hasKnowledge, let client = model.client else { return }
        do { knowledge = .loaded(try await client.view(KnowledgeView.self, "knowledge")) } catch { knowledge = .failed(error.friendly) }
        rebuildShelf()
    }
}

/// Documents as the list shows them: one shape for both sources.
struct DocShelf {
    struct Doc: Hashable, Identifiable {
        var id: String
        var title: String
        var summary: String?
        var updatedAt: Date?
        var source: String
        var section: String
        /// §21.7: related items' titles (docgraph tree).
        var related: [String] = []
        var route: DocRoute { DocRoute(id: id, source: source) }
        var key: String { source + ":" + id }
    }
    struct Section: Identifiable { var id: String; var label: String; var summary: String?; var docs: [Doc] }
    var sections: [Section]

    /// Every document once.
    let all: [Doc]

    init(sections: [Section]) {
        self.sections = sections
        var seen = Set<String>()
        all = sections.flatMap(\.docs).filter { seen.insert($0.key).inserted }
    }

    init(_ k: KnowledgeView) {
        self.init(sections: k.areas.map { a in
            Section(id: "k:" + a.id, label: a.label, summary: a.summary,
                    docs: a.docs.map { Doc(id: $0.id, title: $0.title, summary: $0.summary, updatedAt: $0.updatedAt, source: "knowledge", section: a.label) })
        }.filter { !$0.docs.isEmpty })
    }

    init(_ g: DocGraphView) {
        if let tree = g.tree, !tree.isEmpty {
            self.init(sections: tree.map { layer in
                Section(id: "g:" + layer.id, label: layer.label, summary: layer.summary,
                        docs: layer.items.map { Doc(id: $0.id, title: $0.title, summary: $0.summary, updatedAt: $0.updatedAt, source: "docgraph", section: layer.label,
                                                    related: ($0.related ?? []).map(\.title)) })
            }.filter { !$0.docs.isEmpty })
            return
        }
        self.init(sections: g.layers.map { layer in
            Section(id: "g:" + layer.id, label: layer.label, summary: layer.summary,
                    docs: g.nodes.filter { $0.layer == layer.id }.map { Doc(id: $0.id, title: $0.title, summary: $0.summary, updatedAt: $0.updatedAt, source: "docgraph", section: layer.label) })
        }.filter { !$0.docs.isEmpty })
    }

    /// Newest first.
    func recent(_ limit: Int) -> [Doc] {
        Array(all.filter { $0.updatedAt != nil }.sorted { $0.updatedAt! > $1.updatedAt! }.prefix(limit))
    }
}

/// The list: newest on top, then 분야 folded open one at a time; with a query, the hits.
struct DocShelfView: View {
    var shelf: DocShelf
    var query: String
    @Environment(AppModel.self) private var model
    @State private var open: Set<String> = []

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Page {
            if trimmed.isEmpty { tree } else { results }
        }
        .task(id: hitsKey) {
            let q = trimmed
            guard !q.isEmpty else { hits = []; hitsFor = ""; return }
            // Bodies arrive in bursts: wait a moment so a burst is searched once.
            if !hits.isEmpty { try? await Task.sleep(nanoseconds: 120_000_000) }
            if Task.isCancelled { return }
            let docs = shelf.all, bodies = model.docBodies, fromMac = serverHits ?? []
            let found = await Task.detached(priority: .userInitiated) { Self.findLocal(q, docs: docs, bodies: bodies, fromMac: fromMac) }.value
            if !Task.isCancelled { hits = found; hitsFor = q }
        }
        .task(id: trimmed) {
            serverHits = nil
            guard !trimmed.isEmpty else { return }
            // §21.6: the Mac searches every document (more than the list holds); the app still reads what it has, for older Macs.
            if model.capabilities.hasView("knowledge"), let client = model.client {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                if let found = try? await client.view(KnowledgeSearchView.self, "knowledge", query: ["q": trimmed, "limit": "50"]), let results = found.results {
                    serverHits = results.map { r in
                        Hit(doc: DocShelf.Doc(id: r.id, title: r.title, summary: nil, updatedAt: r.updatedAt, source: "knowledge", section: r.areaLabel ?? r.area ?? "문서"),
                            snippet: r.snippet.map { ChatText.preview($0, limit: 120) }, rank: 0)
                    }
                }
            }
            let rest = serverHits == nil ? shelf.all : shelf.all.filter { $0.source != "knowledge" }
            await model.loadDocBodies(rest)
        }
    }

    @State private var serverHits: [Hit]?

    private var hitsKey: HitsKey { HitsKey(q: trimmed, server: serverHits?.count ?? -1, bodies: model.docBodies.count, docs: shelf.all.count) }

    @ViewBuilder private var tree: some View {
        let recent = shelf.recent(5)
        if !recent.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    CardHeader(title: "최근 고친 문서")
                    CardList(items: recent) { row($0, showSection: true) }
                }
            }
        }
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "분야별")
                    .padding(.bottom, 6)
                ForEach(shelf.sections) { section in
                    let isOpen = open.contains(section.id)
                    Button {
                        withAnimation(.snappy) { if isOpen { open.remove(section.id) } else { open.insert(section.id) } }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isOpen ? "folder" : "folder.fill").foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.label).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                if let summary = section.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                            Text("\(section.docs.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isOpen ? "펼침" : "접힘")
                    if isOpen {
                        let docs = section.docs.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                        VStack(spacing: 0) {
                            ForEach(docs) { d in
                                row(d, showSection: false).padding(.leading, 32)
                                if d.id != docs.last?.id { Divider().padding(.leading, 32) }
                            }
                        }
                    }
                    if section.id != shelf.sections.last?.id { Divider() }
                }
            }
        }
        if shelf.sections.isEmpty {
            EmptyStateView(icon: "doc.text", title: "아직 쌓인 문서가 없어요",
                           message: "비서와 이야기하면 정한 것과 알게 된 것이 여기에 문서로 쌓여요.")
        }
    }

    private struct Hit: Identifiable { var doc: DocShelf.Doc; var snippet: String?; var rank: Int; var id: String { doc.key } }

    /// What was found, worked out away from the screen: scanning 900+ documents (and their bodies) on every
    /// keystroke and every body that arrived made typing and scrolling stutter.
    @State private var hits: [Hit] = []
    /// The query `hits` answers (so "없어요" never shows for a query not searched yet).
    @State private var hitsFor = ""

    private struct HitsKey: Equatable { var q: String; var server: Int; var bodies: Int; var docs: Int }

    private static func findLocal(_ q: String, docs: [DocShelf.Doc], bodies: [String: String], fromMac: [Hit]) -> [Hit] {
        let seen = Set(fromMac.map(\.doc.key))
        let local = docs.filter { !seen.contains($0.key) }.compactMap { d -> Hit? in
            if KoreanSearch.matches(d.title, q) { return Hit(doc: d, snippet: d.summary, rank: 0) }
            if let s = d.summary, KoreanSearch.matches(s, q) { return Hit(doc: d, snippet: s, rank: 1) }
            if KoreanSearch.matches(d.section, q) { return Hit(doc: d, snippet: nil, rank: 2) }
            if let body = bodies[d.key], let line = KoreanSearch.snippet(body, q) { return Hit(doc: d, snippet: line, rank: 3) }
            return nil
        }
        .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : ($0.doc.updatedAt ?? .distantPast) > ($1.doc.updatedAt ?? .distantPast) }
        return fromMac + local
    }

    @ViewBuilder private var results: some View {
        let found = hits
        let reading = model.docBodiesLoading
        if !found.isEmpty {
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    CardHeader(title: "찾은 문서 \(found.count)개", subtitle: reading.map { "본문 읽는 중 \($0.done)/\($0.total) — 더 나올 수 있어요" })
                    CardList(items: found) { hit in
                        NavigationLink(value: hit.doc.route) {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(highlighted(hit.doc.title)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    if let s = hit.snippet { Text(highlighted(s)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                    Text(highlighted(hit.doc.section) + AttributedString(hit.doc.updatedAt.map { " · \(Format.relative($0)) 고침" } ?? ""))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if hitsFor != trimmed {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if let reading {
            EmptyStateView(icon: "magnifyingglass", title: "본문까지 찾는 중이에요", message: "문서 \(reading.total)개 중 \(reading.done)개를 읽었어요.")
        } else {
            EmptyStateView(icon: "magnifyingglass", title: "‘\(trimmed)’이(가) 들어간 문서가 없어요",
                           message: "문서 \(shelf.all.count)개의 제목·분야·내용을 모두 찾아봤어요." +
                                    (model.docBodiesFailed > 0 ? " 내용을 읽지 못한 문서가 \(model.docBodiesFailed)개 있어요." : "") +
                                    "\n띄어쓰기는 상관없고, 첫소리(예: ㄱㅈ)로도 찾을 수 있어요.")
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        if let r = KoreanSearch.range(in: text, of: trimmed), let lower = AttributedString.Index(r.lowerBound, within: a), let upper = AttributedString.Index(r.upperBound, within: a) {
            a[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            a[lower..<upper].foregroundColor = .primary
            a[lower..<upper].backgroundColor = Color.yellow.opacity(0.35)
        }
        return a
    }

    private func row(_ d: DocShelf.Doc, showSection: Bool) -> some View {
        NavigationLink(value: d.route) {
            CardRow(title: d.title, detail: [showSection ? d.section : nil, d.summary.map { ChatText.preview($0, limit: 60) },
                                             d.related.isEmpty ? nil : "관련: " + d.related.prefix(3).joined(separator: ", "), d.updatedAt.map { "\(Format.relative($0)) 고침" }]
                .compactMap { $0 }.joined(separator: " · ")) {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct DocumentScreen: View {
    /// The title is already on top: a first heading that repeats it goes.
    static func withoutTitle(_ markdown: String, _ title: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first, let m = first.firstMatch(of: #/^#{1,3}\s+(.*)$/#),
           String(m.1).trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    /// Source notes written for the machine ("transcript:35e5….jsonl:667520") read as "대화 기록".
    static func readable(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"transcript:[A-Za-z0-9-]+(\.jsonl)?(:[^\s)+,]*)?"#, with: "대화 기록", options: .regularExpression)
            .replacingOccurrences(of: #"memory/[A-Za-z0-9._-]+\.md"#, with: "메모", options: .regularExpression)
    }

    var id: String
    /// Which view answers `?doc=`: `docgraph` or `knowledge` (the one the document came from).
    var source = "docgraph"
    /// The search that led here: the first matching line is marked.
    var highlight = ""
    @Environment(AppModel.self) private var model
    @State private var state: Loadable<DocumentDetail?> = .loading
    @State private var asking = false

    var body: some View {
        LoadableView(state: state, retry: load) { doc in
            if let doc {
                Page {
                    Panel {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(doc.title).font(.title2.bold())
                                if let at = doc.updatedAt { Text("\(Format.relative(at)) 고침").font(.footnote).foregroundStyle(.secondary) }
                            }
                            if !highlight.trimmingCharacters(in: .whitespaces).isEmpty, let line = KoreanSearch.snippet(doc.markdown, highlight, width: 120) {
                                Label {
                                    Text(line).font(.subheadline)
                                } icon: { Image(systemName: "magnifyingglass") }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityLabel("찾은 곳: \(line)")
                            }
                            MarkdownDocument(source: Self.readable(Self.withoutTitle(doc.markdown, doc.title)))
                        }
                    }
                    if let related = doc.related, !related.isEmpty {
                        Panel {
                            VStack(alignment: .leading, spacing: 4) {
                                CardHeader(title: "관련 문서")
                                CardList(items: related) { r in
                                    NavigationLink(value: DocRoute(id: r.id, source: "docgraph")) {
                                        CardRow(title: r.title) {
                                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Button("틀린 곳이 있으면 비서에게 알려 주기") { asking = true }
                        .buttonStyle(.action(.secondary))
                }
                // A sheet, not an alert: an alert closes on the tap, before a Hangul syllable being typed is finished,
                // so half a sentence went out and then the whole one again.
                .sheet(isPresented: $asking) {
                    DocFixSheet(title: doc.title) { text in
                        model.send("[문서 고치기: \(doc.title)] \(text)", in: "")
                        model.toast = "비서에게 보냈어요. 고치면 알려 드릴게요."
                    }
                    .presentationDetents([.medium])
                }
            } else {
                EmptyStateView(icon: "doc", title: "문서를 찾지 못했어요")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { state = .loading; await load() }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(DocumentEnvelope.self, source, query: highlight.trimmingCharacters(in: .whitespaces).isEmpty ? ["doc": id] : ["doc": id, "q": highlight]).document) }
        catch { state = .failed(error.friendly) }
    }
}

/// "틀린 곳이 있으면 비서에게 알려 주기": what to fix, sent once with the whole text.
private struct DocFixSheet: View {
    var title: String
    var send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fix = ""
    @State private var sent = false
    @FocusState private var focused: Bool

    private var trimmed: String { fix.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("예: 투자 목표는 50억이에요", text: $fix, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                } footer: {
                    Text(verbatim: "'\(title)' 문서에서 틀린 곳을 비서에게 알려요.")
                }
            }
            .navigationTitle("무엇을 고칠까요?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("보내기") {
                        guard !sent else { return }
                        TextComposition.finish {
                            guard !sent, !trimmed.isEmpty else { return }
                            sent = true
                            send(trimmed)
                            dismiss()
                        }
                    }
                    .disabled(trimmed.isEmpty || sent)
                }
            }
            .onAppear { focused = true }
        }
    }
}
