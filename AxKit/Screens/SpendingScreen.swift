import AxKitCore
import SwiftUI

/// 지출 관리: this month's total against the budget, by category, and every entry (tap to fix its category).
struct SpendingScreen: View {
    @Environment(AppModel.self) private var model
    @State private var month = String(Format.ymd(Date()).prefix(7))
    @State private var state: Loadable<SpendingView> = .loading
    @State private var editing: SpendingView.Entry?
    @State private var adding = false
    @State private var budgetText = ""
    @State private var editingBudget = false

    private func can(_ action: String) -> Bool { model.capabilities.view("spending")?.actions?.contains(action) == true }

    var body: some View {
        LoadableView(state: state, retry: load) { s in
            Page {
                Panel { summary(s) }
                if !s.byCategory.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            CardHeader(title: "어디에 썼나")
                            let top = s.byCategory.first?.amount ?? 1
                            ForEach(s.byCategory, id: \.category) { c in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(c.label); Spacer(); Text(Format.won(c.amount)).monospacedDigit().foregroundStyle(.secondary) }.font(.subheadline)
                                    ProgressView(value: c.amount / max(top, 1)).tint(.accentColor)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                if let subs = s.subscriptions, !subs.isEmpty {
                    KVCard(title: "매달 나가는 돈", items: subs.map { sub in
                        KV(title: sub.merchant, value: Format.won(sub.amount) + (sub.nextDate.map { " · \($0.suffix(5).replacingOccurrences(of: "-", with: "/"))" } ?? ""))
                    })
                }
                Panel {
                    VStack(alignment: .leading, spacing: 4) {
                        CardHeader(title: "내역")
                        CardList(items: s.entries ?? []) { e in
                            CardRow(title: e.merchant, detail: "\(e.date.suffix(5).replacingOccurrences(of: "-", with: "/")) · \(e.categoryLabel ?? "분류 없음")") {
                                Text(Format.won(e.amount)).monospacedDigit().foregroundStyle(e.amount < 0 ? .green : .primary)
                            }
                            .safeTap { if can("categorize") { editing = e } }
                            .accessibilityHint(can("categorize") ? "눌러서 분류를 바꿔요" : "")
                        }
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("지출 관리")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("지난달")
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("다음 달")
                if can("add") { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("직접 적기") }
            }
        }
        .task(id: month) { await load() }
        .sheet(item: $editing) { e in CategorySheet(entry: e, categories: state.value?.categories ?? []) { await load() } }
        .sheet(isPresented: $adding) { AddEntrySheet(categories: state.value?.categories ?? []) { await load() } }
        .alert("한 달 예산", isPresented: $editingBudget) {
            TextField("예: 1200000", text: $budgetText).keyboardType(.numberPad)
            Button("저장") { Task { await saveBudget() } }
            Button("예산 없애기", role: .destructive) { budgetText = ""; Task { await saveBudget() } }
            Button("취소", role: .cancel) {}
        }
    }

    private func summary(_ s: SpendingView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Int(s.month.suffix(2)) ?? 0)월에 쓴 돈").font(.subheadline).foregroundStyle(.secondary)
            Text(Format.won(s.total)).font(.system(.largeTitle, design: .rounded).bold())
            if let budget = s.budget, budget > 0 {
                ProgressView(value: min(s.total / budget, 1))
                    .tint(s.total > budget ? .red : s.total > budget * 0.8 ? .orange : .green)
                Text(s.total > budget ? "예산보다 \(Format.won(s.total - budget)) 더 썼어요" : "예산 \(Format.won(budget)) 중 \(Format.won(budget - s.total)) 남았어요")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let prev = s.previousTotal, prev > 0 {
                let diff = s.total - prev
                Text(diff >= 0 ? "지난달보다 \(Format.won(diff)) 더 썼어요" : "지난달보다 \(Format.won(-diff)) 덜 썼어요").font(.footnote).foregroundStyle(.secondary)
            }
            if can("budget") {
                Button(s.budget == nil ? "예산 정하기" : "예산 바꾸기") {
                    budgetText = s.budget.map { String(Int($0)) } ?? ""
                    editingBudget = true
                }
                .buttonStyle(.action(.secondary, fullWidth: false, small: true))
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func shift(_ n: Int) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Format.seoul
        let first = c.date(from: DateComponents(year: Int(month.prefix(4)), month: Int(month.suffix(2)), day: 1)) ?? Date()
        if let next = c.date(byAdding: .month, value: n, to: first) { month = String(Format.ymd(next).prefix(7)) }
    }

    private func load() async {
        guard let client = model.client else { return }
        do { state = .loaded(try await client.view(SpendingView.self, "spending", query: ["month": month])) } catch { state = .failed(error.friendly) }
    }

    private struct Ack: Decodable {}

    private func saveBudget() async {
        guard let client = model.client else { return }
        let value: Any = Double(budgetText.filter(\.isNumber)).map { $0 as Any } ?? NSNull()
        do { _ = try await client.viewAction(Ack.self, "spending", "budget", json: ["monthly": value]) } catch { model.toast = error.friendly }
        await load()
    }
}

private struct CategorySheet: View {
    var entry: SpendingView.Entry
    var categories: [SpendingView.CategoryChoice]
    var done: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var remember = true

    private struct Ack: Decodable {}

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(entry.merchant, value: Format.won(entry.amount))
                    Toggle("다음부터 '\(entry.merchant)'은 늘 이 분류로", isOn: $remember)
                }
                Section("분류 고르기") {
                    ForEach(categories) { c in
                        Button {
                            Task {
                                do {
                                    _ = try await model.client?.viewAction(Ack.self, "spending", "categorize", json: ["entryId": entry.id, "category": c.id, "remember": remember])
                                    model.toast = "'\(c.label)'(으)로 바꿨어요"
                                } catch { model.toast = error.friendly }
                                await done()
                                dismiss()
                            }
                        } label: {
                            HStack { Text(c.label).foregroundStyle(.primary); Spacer(); if c.id == entry.category { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }
            .navigationTitle("분류 바꾸기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AddEntrySheet: View {
    var categories: [SpendingView.CategoryChoice]
    var done: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var merchant = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var category = "other"

    private struct Ack: Decodable {}

    var body: some View {
        NavigationStack {
            Form {
                TextField("어디서 (예: 시장)", text: $merchant)
                TextField("얼마 (원)", text: $amount).keyboardType(.numberPad)
                DatePicker("언제", selection: $date, displayedComponents: .date)
                Picker("분류", selection: $category) { ForEach(categories) { Text($0.label).tag($0.id) } }
            }
            .navigationTitle("현금 지출 적기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("적기") {
                        Task {
                            do {
                                _ = try await model.client?.viewAction(Ack.self, "spending", "add", json: [
                                    "merchant": merchant, "amount": Double(amount.filter(\.isNumber)) ?? 0, "date": Format.ymd(date), "category": category,
                                ])
                                model.toast = "적었어요"
                            } catch { model.toast = error.friendly }
                            await done()
                            dismiss()
                        }
                    }
                    .disabled(merchant.isEmpty || (Double(amount.filter(\.isNumber)) ?? 0) <= 0)
                }
            }
        }
    }
}
