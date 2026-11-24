import AxKitCore
import SwiftUI
import VisionKit

/// First screen and "다른 맥에 연결": scan the Mac's QR, or paste its link.
struct PairView: View {
    var isOnboarding: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var pasting = false
    @State private var linkText = ""
    @State private var working = false
    @State private var error: String?

    static func message(for error: Error) -> String {
        if let parse = error as? PairingLink.ParseError {
            switch parse {
            case .insecureAddress: return "안전하지 않은 주소예요. https 주소나 집·Tailscale 주소만 연결할 수 있어요."
            default: return "ax-kit 연결 QR이 아니에요. 맥에 뜬 QR을 다시 찍어 주세요."
            }
        }
        return error.friendly
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "macmini.fill").font(.system(size: 44)).foregroundStyle(.tint)
                    Text(isOnboarding ? "내 맥과 연결해요" : "다른 맥에 연결").font(.largeTitle.bold())
                    Text("비서는 집에 있는 맥에서 일해요. 아이폰은 그 맥과 이야기하는 창이에요.")
                        .foregroundStyle(.secondary)
                }

                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Step(number: 1, text: "맥의 터미널에서 이렇게 입력해요", code: "ax-kit phone pair --app --platform ios")
                        Step(number: 2, text: "맥 화면에 뜬 QR을 아래 버튼으로 찍어요")
                        Step(number: 3, text: "끝! 이제 어디서든 비서와 이야기할 수 있어요")
                    }
                }

                VStack(spacing: 12) {
                    Button { scanning = true } label: {
                        Label("QR 찍기", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button { pasting = true } label: {
                        Label("연결 링크 붙여넣기", systemImage: "link").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    #if DEBUG
                    Button { connect(AppModel.mockLink) } label: {
                        Label("개발용 가짜 맥에 연결", systemImage: "hammer").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("mock-pair")
                    #endif
                }
                .disabled(working)

                if working { ProgressView("맥과 연결하는 중…").frame(maxWidth: .infinity) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.subheadline)
                }

                Label("집 밖에서도 쓰려면 아이폰에 Tailscale 앱을 켜 두세요. 연결 정보는 이 아이폰 키체인에만 저장돼요.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Theme.page)
        .sheet(isPresented: $scanning) {
            QRScannerSheet { code in
                scanning = false
                connect(code)
            }
        }
        .alert("연결 링크 붙여넣기", isPresented: $pasting) {
            TextField("axkit://pair?…", text: $linkText)
            Button("연결") { connect(linkText) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("맥에 나온 'axkit://pair' 로 시작하는 링크를 넣어 주세요.")
        }
    }

    private func connect(_ link: String) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await model.pair(link: link)
                model.toast = "맥과 연결됐어요"
                if !isOnboarding { dismiss() }
            } catch {
                self.error = Self.message(for: error)
            }
        }
    }
}

private struct Step: View {
    var number: Int
    var text: String
    var code: String?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                if let code {
                    Text(code).font(.system(.footnote, design: .monospaced)).padding(8)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct QRScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner(onCode: onCode).ignoresSafeArea()
                } else {
                    EmptyStateView(icon: "camera.fill", title: "카메라를 쓸 수 없어요",
                                   message: "설정에서 카메라를 허용하거나, '연결 링크 붙여넣기'를 써 주세요.")
                }
            }
            .navigationTitle("맥의 QR을 비춰 주세요")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                if case .barcode(let code) = item, let value = code.payloadStringValue, value.hasPrefix("axkit://"), !done {
                    done = true
                    scanner.stopScanning()
                    onCode(value)
                }
            }
        }
    }
}
