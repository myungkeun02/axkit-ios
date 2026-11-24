import AxKitCore
import CoreLocation
import Foundation
import Observation
import UIKit

/// Tells the Mac where the phone is (`POST location`), only when the Mac lists the `location` feature.
/// On open, every 20 minutes while open, and on a real move (significant-change; with "항상 허용" that also
/// works with the app closed). Nothing is kept on the phone except the last fix sent.
@MainActor @Observable
final class LocationReporter: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    private(set) var lastSentAt: Date?

    private let manager = CLLocationManager()
    private var client: APIClient?
    private var refreshTask: Task<Void, Never>?
    private var lastSent: LocationPolicy.Fix?
    private var opening = false
    private var sending = false

    /// The Mac said it wants the phone's place (kept so a background relaunch can send before capabilities load).
    private static let enabledKey = "location.enabled"
    static var macWantsIt: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = LocationPolicy.moved
        manager.pausesLocationUpdatesAutomatically = true
    }

    var authorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    /// After capabilities load (and on open): start or stop.
    func update(client: APIClient?, wanted: Bool, active: Bool) {
        self.client = client
        Self.macWantsIt = wanted && client != nil
        guard Self.macWantsIt else { stopAll(); return }
        switch status {
        case .notDetermined:
            if active { manager.requestWhenInUseAuthorization() }
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startMonitoringSignificantLocationChanges()
            // Already ticking while open: capabilities refreshing again is not a reason to ask for a new fix.
            if active, refreshTask == nil { appOpened() }
        default:
            stopAll()
        }
    }

    /// Asks once for "항상 허용" so moves are sent with the app closed too (iOS shows its own choice).
    func askAlways() { manager.requestAlwaysAuthorization() }

    func appOpened() {
        guard Self.macWantsIt, authorized else { return }
        opening = true
        manager.requestLocation()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(LocationPolicy.refresh * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.manager.requestLocation()
            }
        }
    }

    func appClosed() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func stopAll() {
        appClosed()
        manager.stopMonitoringSignificantLocationChanges()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.status = status
            self.update(client: self.client, wanted: Self.macWantsIt, active: UIApplication.shared.applicationState == .active)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let best = locations.max(by: { $0.timestamp < $1.timestamp }) else { return }
        let fix = LocationPolicy.Fix(lat: best.coordinate.latitude, lng: best.coordinate.longitude,
                                     accuracy: best.horizontalAccuracy, at: best.timestamp)
        Task { @MainActor in await self.consider(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func consider(_ fix: LocationPolicy.Fix) async {
        let wasOpening = opening
        opening = false
        guard Self.macWantsIt, !sending, LocationPolicy.shouldSend(fix, last: lastSent, opening: wasOpening) else { return }
        // A relaunch for a move in the background: the model may not have a client yet.
        guard let client = client ?? AppModel.shared.client else { return }
        sending = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "send-location")
        defer { UIApplication.shared.endBackgroundTask(task); sending = false }
        do {
            try await client.reportLocation(lat: fix.lat, lng: fix.lng, accuracyM: fix.accuracy)
            lastSent = fix
            lastSentAt = Date()
        } catch {
            // Not sent: the next fix (or the next 20-minute tick) tries again.
        }
    }
}
