import AxKitCore
import QuickLook
import SwiftUI

/// Pictures that come with a message or card: `files/<id>` (needs the device token) or one https `imageUrl`.
struct AttachedImages: View {
    var attachments: [Attachment]?
    var imageUrl: String?
    var height: CGFloat = 220

    private var refs: [String] {
        (attachments ?? []).filter { $0.contentType.hasPrefix("image/") }.map(\.url) + (imageUrl.map { [$0] } ?? [])
    }

    var body: some View {
        if !refs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(refs, id: \.self) { RemoteImage(ref: $0, height: height) }
                }
            }
            .scrollDisabled(refs.count == 1)
        }
    }
}

struct RemoteImage: View {
    var ref: String
    var height: CGFloat
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var failed = false
    @State private var fullScreen = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.title3)
                    Text("사진을 불러오지 못했어요").font(.caption).multilineTextAlignment(.center).minimumScaleFactor(0.7)
                }
                .foregroundStyle(.secondary)
                .padding(8)
            } else {
                ProgressView()
            }
        }
        .frame(width: image.map { min(height * $0.size.width / max($0.size.height, 1), 300) } ?? (failed ? min(height, 180) : height * 0.8),
               height: failed ? min(height, 110) : height)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if image != nil { fullScreen = true } }
        .accessibilityLabel("첨부 사진")
        .accessibilityAddTraits(.isImage)
        .task(id: ref) {
            image = await model.avatarImage(ref)
            failed = image == nil
        }
        .fullScreenCover(isPresented: $fullScreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
                Button { fullScreen = false } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white).padding(12).background(.white.opacity(0.2), in: Circle())
                }
                .padding()
                .accessibilityLabel("닫기")
            }
        }
    }
}

/// Files that aren't pictures (PDF, 한글, 엑셀, zip …): a row with name and size; tap to download and open
/// in the system preview, where it can also be shared or saved to Files. Kept 30 days on the Mac (§19).
struct AttachedFiles: View {
    var attachments: [Attachment]?

    var body: some View {
        let files = (attachments ?? []).filter { !$0.contentType.hasPrefix("image/") }
        if !files.isEmpty {
            VStack(spacing: 6) { ForEach(files) { FileRow(file: $0) } }
        }
    }
}

private struct FileRow: View {
    var file: Attachment
    @Environment(AppModel.self) private var model
    @State private var loading = false
    @State private var preview: URL?

    private var icon: String {
        let name = file.name.lowercased()
        if name.hasSuffix(".pdf") { return "doc.richtext" }
        if name.hasSuffix(".zip") { return "doc.zipper" }
        if [".xls", ".xlsx"].contains(where: name.hasSuffix) { return "tablecells" }
        if [".ppt", ".pptx"].contains(where: name.hasSuffix) { return "rectangle.on.rectangle" }
        if [".doc", ".docx", ".hwp", ".hwpx"].contains(where: name.hasSuffix) { return "doc.text.fill" }
        return "doc.text"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(file.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "파일")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if loading { ProgressView() } else { Image(systemName: "arrow.down.circle").foregroundStyle(.tint) }
        }
        .padding(12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .safeTap { Task { await open() } }
        .accessibilityLabel("파일 \(file.name), 눌러서 열기")
        .quickLookPreview($preview)
    }

    private func open() async {
        guard let client = model.client, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await client.file(file.url)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ax-files", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeName = file.name.replacingOccurrences(of: "/", with: "_")
            let url = folder.appendingPathComponent(safeName)
            try data.write(to: url, options: .atomic)
            preview = url
        } catch APIError.notFound {
            model.toast = "파일이 지워졌어요. 맥에는 30일만 보관돼요. 비서에게 다시 보내 달라고 해 주세요."
        } catch {
            model.toast = error.friendly
        }
    }
}
