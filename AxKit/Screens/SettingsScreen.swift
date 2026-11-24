import AxKitCore
import SwiftUI

/// 설정 및 연결: which Mac, is it reachable, pair again, unpair.
struct SettingsScreen: View {
    var inSheet = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnpair = false
    @State private var refreshing = false

    var body: some View {
        Page {
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: "macmini").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.credentials?.displayHost ?? "연결된 맥 없음").font(.headline)
                            HStack(spacing: 6) {
                                Circle().fill(model.connection.color).frame(width: 8, height: 8)
                                Text(model.connection.label).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if case .offline(let why) = model.connection {
                        Text(why + " 집 밖이라면 아이폰의 Tailscale이 켜져 있는지 확인해 주세요.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.connection == .unauthorized {
                        Text("맥이 이 아이폰을 더 이상 알지 못해요. 아래 '다른 맥에 연결'로 QR을 다시 찍어 주세요.").font(.footnote).foregroundStyle(.red)
                    }
                    Button {
                        refreshing = true
                        Task {
                            model.stop()
                            model.start()
                            await model.refreshBasics()
                            refreshing = false
                        }
                    } label: {
                        HStack { Text("지금 다시 연결해 보기"); if refreshing { Spacer(); ProgressView() } }
                    }
                    .buttonStyle(.action(.secondary))
                }
            }
            KVCard(title: "이 아이폰", items: [
                KV(title: "이름", value: model.credentials?.deviceName ?? "-"),
                model.credentials.map { KV(title: "연결한 날", value: Format.relative($0.pairedAt)) },
                KV(title: "비서 이름", value: model.assistantName),
                KV(title: "앱 버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"),
            ].compactMap { $0 })
            if model.capabilities.has("location") { LocationPanel(location: model.location) }
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    NavigationLink { PairView(isOnboarding: false) } label: { Text("다른 맥에 연결 (QR 다시 찍기)") }
                        .buttonStyle(.action(.secondary))
                    Button("연결 끊기") { confirmUnpair = true }
                        .buttonStyle(.action(.danger))
                    Text("연결 정보(토큰)는 이 아이폰 키체인에만 있어요. 연결을 끊으면 맥에서도 바로 지워져요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("설정 및 연결")
        .toolbar {
            if inSheet { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
        .confirmationDialog("이 맥과 연결을 끊을까요?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("연결 끊기", role: .destructive) { Task { await model.unpair(); if inSheet { dismiss() } } }
            Button("그대로 두기", role: .cancel) {}
        } message: {
            Text("다시 쓰려면 맥에서 QR을 새로 띄워야 해요.")
        }
    }
}

/// Where the phone is: whether the Mac gets it, and the way to "항상 허용" (moves sent with the app closed).
private struct LocationPanel: View {
    var location: LocationReporter
    @Environment(\.openURL) private var openURL

    private var words: String {
        switch location.status {
        case .authorizedAlways: "항상 보내요. 앱을 닫아 두어도 크게 움직이면 알려요."
        case .authorizedWhenInUse: "앱을 쓰는 동안 보내요."
        case .denied, .restricted: "꺼져 있어요. 설정에서 위치를 켜면 길찾기·근처 추천이 지금 계신 곳 기준이 돼요."
        default: "아직 묻지 않았어요."
        }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: "위치")
                Text(words).font(.subheadline)
                if let at = location.lastSentAt {
                    Text("마지막으로 보낸 때: \(Format.relative(at))").font(.footnote).foregroundStyle(.secondary)
                }
                switch location.status {
                case .authorizedWhenInUse:
                    Button("앱을 닫아도 보내기 (항상 허용)") { location.askAlways() }.buttonStyle(.action(.secondary))
                case .denied, .restricted:
                    Button("설정 열기") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                        .buttonStyle(.action(.secondary))
                default:
                    EmptyView()
                }
                Text("위치는 내 맥에만 가요. 맥은 최근 30분 안의 위치만 '지금 있는 곳'으로 써요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
