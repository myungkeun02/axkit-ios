import AxKitCore
import CoreLocation
import SwiftUI

/// 휴대폰 신호: what this phone tells the Mac by itself (each its own switch), and what iOS doesn't let an app read.
struct PhoneSignalsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var location: LocationReporter { model.location }
    private var signals: SignalsReporter { model.signals }

    var body: some View {
        Page {
            Text("켜 둔 것만 내 맥에 보내요. 비서가 장소 추천·이동 시간·하루 요약·알림 줄이기에 써요.")
                .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            locationPanel
            switchPanel(title: "배터리", icon: "battery.25",
                        detail: "20%·10%·5% 아래로 떨어질 때 한 번씩 알려요. 충전 중에는 보내지 않아요. 앱이 열려 있거나 위치 때문에 잠깐 깨어날 때만 확인할 수 있어요.",
                        isOn: Binding(get: { signals.batteryOn }, set: { signals.setBattery($0) }),
                        last: signals.lastSent[.battery])
            if signals.stepsAvailable {
                switchPanel(title: "걸음", icon: "figure.walk",
                            detail: "하루에 한 번, 어제 걸은 수만 건강 앱에서 읽어 보내요.",
                            isOn: Binding(get: { signals.stepsOn }, set: { signals.setSteps($0) }),
                            last: signals.lastSent[.steps]) {
                    if signals.stepsOn, signals.stepsBlocked {
                        Text("건강 앱에서 걸음 읽기를 허용해 주세요: 건강 › 공유 › 앱 › \(model.assistantName)")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    Label("문자·다른 앱 알림", systemImage: "message").font(.headline)
                    Text("아이폰에서는 앱이 문자나 다른 앱의 알림을 읽을 수 없어요. 문자는 지금처럼 단축어 자동화가 보내요.")
                        .font(.subheadline)
                    Text("아직 없으면 비서 맥에서 `ax-kit phone pair --platform ios`로 단축어를 받고, 단축어 앱 › 자동화 › 메시지에 연결해 주세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("휴대폰 신호")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: location

    private var macTakesIt: Bool { model.capabilities.has("location") }

    private var locationWords: String {
        switch location.status {
        case .authorizedAlways: "항상 보내요. 앱을 닫아 두어도 크게 움직이거나 어딘가에 도착·출발하면 알려요."
        case .authorizedWhenInUse: "앱을 쓰는 동안만 보내요. 닫아 두어도 보내려면 '항상'으로 바꿔 주세요."
        case .denied, .restricted: "위치가 꺼져 있어요. 설정에서 켜 주세요."
        default: "켜면 위치를 써도 되는지 물어봐요. '항상'을 고르면 앱을 닫아 두어도 보내요."
        }
    }

    private var locationPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { location.ownerOn || macTakesIt }, set: { location.setOwnerSwitch($0) })) {
                    Label("위치", systemImage: "location").font(.headline)
                }
                .tint(.accentColor)
                .disabled(macTakesIt)
                if location.ownerOn || macTakesIt {
                    Text(locationWords).font(.subheadline)
                    switch location.status {
                    case .authorizedWhenInUse:
                        Button("앱을 닫아도 보내기 (항상 허용)") { location.askAlways() }.buttonStyle(.action(.secondary))
                    case .denied, .restricted:
                        Button("설정 열기") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                            .buttonStyle(.action(.secondary))
                    default: EmptyView()
                    }
                    if let at = location.lastSentAt {
                        Text("마지막으로 보낸 때: \(Format.relative(at))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text(macTakesIt ? "이 맥은 위치를 늘 받아요(설정 및 연결에서도 볼 수 있어요)." : "크게 움직였을 때와 도착·출발했을 때만 보내요. 길게 쌓아 두지 않아요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: a switch

    private func switchPanel(title: String, icon: String, detail: String, isOn: Binding<Bool>, last: Date?,
                             @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: isOn) { Label(title, systemImage: icon).font(.headline) }.tint(.accentColor)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                extra()
                if isOn.wrappedValue, let last {
                    Text("마지막으로 보낸 때: \(Format.relative(last))").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
