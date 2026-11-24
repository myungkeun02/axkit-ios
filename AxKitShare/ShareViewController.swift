import AxKitCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "ax-kit으로 보내기" from any app: text, links, pictures and files go straight to the Mac's assistant.
/// If the Mac can't be reached, they wait in the shared folder and the app sends them when it opens.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(context: extensionContext))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct ShareView: View {
    let context: NSExtensionContext?
    @State private var note = ""
    @State private var preview = "불러오는 중…"
    @State private var state: Step = .ready
    @State private var payload: Payload?

    enum Step: Equatable { case ready, sending, sent(String), failed(String) }
    struct Payload { var text: String?; var bytes: Data?; var name: String?; var type: String? }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                TextField("비서에게 한마디 (예: 이거 정리해 줘)", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                switch state {
                case .sent(let words): Label(words, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let words): Text(words).foregroundStyle(.red).font(.footnote)
                default: EmptyView()
                }
                Spacer()
            }
            .padding(16)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("비서에게 보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { context?.completeRequest(returningItems: nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(state == .sending ? "보내는 중" : "보내기") { Task { await send() } }
                        .disabled(payload == nil || state == .sending)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let providers = (context?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data = await imageData(provider) {
                payload = Payload(bytes: data, name: provider.suggestedName.map { $0 + ".jpg" } ?? "사진.jpg", type: "image/jpeg")
                preview = "사진 1장"
                return
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                if url.isFileURL, let data = try? Data(contentsOf: url) {
                    payload = Payload(bytes: data, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
                    preview = "파일: \(url.lastPathComponent)"
                } else {
                    payload = Payload(text: url.absoluteString)
                    preview = url.absoluteString
                }
                return
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                payload = Payload(text: text)
                preview = text
                return
            }
        }
        preview = "보낼 수 있는 내용이 없어요."
    }

    private func imageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in cont.resume(returning: data) }
        }
    }

    private func send() async {
        guard let payload else { return }
        state = .sending
        let message = [note.trimmingCharacters(in: .whitespacesAndNewlines), payload.text ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        let item = SharedPlace.SharedItem(text: message.isEmpty ? nil : message, fileName: payload.name, contentType: payload.type)
        guard let credentials = SharedPlace.credentialStore().load() else {
            state = .failed("아직 맥과 연결되지 않았어요. ax-kit 앱에서 먼저 연결해 주세요.")
            return
        }
        let client = APIClient(credentials: credentials)
        do {
            if let bytes = payload.bytes, let name = payload.name {
                _ = try await client.share(bytes, name: name, contentType: payload.type ?? "application/octet-stream")
                if !note.isEmpty { _ = try await client.sendMessage(text: note, clientId: item.id) }
            } else if let text = item.text {
                _ = try await client.sendMessage(text: text, clientId: item.id)
            }
            state = .sent("비서에게 보냈어요")
        } catch let error as APIError where error.isTransient {
            SharedPlace.queue(item, bytes: payload.bytes)
            state = .sent("맥이 연결되면 보낼게요")
        } catch {
            state = .failed(error.friendly)
            return
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        context?.completeRequest(returningItems: nil)
    }
}

extension Error {
    var friendly: String { (self as? APIError)?.friendlyMessage ?? "잠깐 문제가 생겼어요. 다시 해 주세요." }
}
