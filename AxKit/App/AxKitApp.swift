import SwiftUI

@main
struct AxKitApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var push
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onAppear { push.attach(model) }
                .onOpenURL { url in
                    guard url.scheme == "axkit" else { return }
                    // From the widget: axkit://open/approvals | axkit://open/home. Also axkit://open/room?id=<방>,
                    // axkit://open/rooms (방 목록), axkit://open/today, axkit://open/more?v=<화면>, axkit://open/docs, axkit://open/calendar.
                    if url.host == "open" {
                        model.open(url)
                        return
                    }
                    Task {
                        do { try await model.pair(link: url.absoluteString); model.toast = "맥과 연결됐어요" }
                        catch { model.toast = PairView.message(for: error) }
                    }
                }
                #if DEBUG
                // Simulator checks without taps: `-devLink <axkit://…>` pairs or opens like a tapped link.
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-devLink"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
                        if url.host == "open" { try? await Task.sleep(nanoseconds: 1_500_000_000); model.open(url) }
                        else { try? await model.pair(link: url.absoluteString) }
                    }
                }
                #endif
                .onChange(of: phase, initial: true) { _, phase in
                    // The stream lives only while the app is in front (§3.1); catch-up fills the gap on return.
                    if phase == .active { model.start() } else if phase == .background { model.stop() }
                    // `-noPush` (simulator checks): no notification prompt covering the screen.
                    if phase == .active, !ProcessInfo.processInfo.arguments.contains("-noPush") { model.push = push }
                }
        }
    }
}
