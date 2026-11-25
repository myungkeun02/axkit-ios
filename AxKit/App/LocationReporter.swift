import AxKitCore
import CoreLocation
import Foundation
import Observation
import UIKit

/// Tells the Mac where the phone is: `POST location` when the Mac lists the `location` feature, otherwise (the owner
/// turned on 휴대폰 신호 › 위치) as a signal to `POST /m/v1/ingest`. On open, every 20 minutes while open, on a real
/// move (significant-change) and on a visit (arrived or left a place); with "항상 허용" the last two also work with the
/// app closed. Nothing is kept on the phone except the last fix sent.
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
    /// The Mac takes `POST location` (else the fix goes as an ingest signal).
    private static let appRouteKey = "location.appRoute"
    static var appRoute: Bool {
        get { UserDefaults.standard.bool(forKey: appRouteKey) }
        set { UserDefaults.standard.set(newValue, forKey: appRouteKey) }
    }
    /// 휴대폰 신호 › 위치 (the owner's own switch; off until turned on).
    static var ownerWantsIt: Bool {
        get { UserDefaults.standard.bool(forKey: "signals.location") }
        set { UserDefaults.standard.set(newValue, forKey: "signals.location") }
    }
    private(set) var ownerOn = LocationReporter.ownerWantsIt
    private var macFeature = false

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = LocationPolicy.moved
        manager.pausesLocationUpdatesAutomatically = true
    }

    var authorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    /// After capabilities load (and on open): start or stop. `wanted`: the Mac lists `location`.
    func update(client: APIClient?, wanted: Bool, active: Bool) {
        self.client = client
        macFeature = wanted
        if client != nil { Self.appRoute = wanted }
        Self.macWantsIt = (wanted || Self.ownerWantsIt) && client != nil
        guard Self.macWantsIt else { stopAll(); return }
        switch status {
        case .notDetermined:
            // The owner's switch asks for "항상" (moves and visits with the app closed); the Mac's feature starts smaller.
            if active { if Self.ownerWantsIt { manager.requestAlwaysAuthorization() } else { manager.requestWhenInUseAuthorization() } }
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startMonitoringSignificantLocationChanges()
            if status == .authorizedAlways, Self.ownerWantsIt { manager.startMonitoringVisits() } else { manager.stopMonitoringVisits() }
            // Already ticking while open: capabilities refreshing again is not a reason to ask for a new fix.
            if active, refreshTask == nil { appOpened() }
        default:
            stopAll()
        }
    }

    /// Asks once for "항상 허용" so moves are sent with the app closed too (iOS shows its own choice).
    func askAlways() { manager.requestAlwaysAuthorization() }

    /// 휴대폰 신호 › 위치.
    func setOwnerSwitch(_ on: Bool) {
        Self.ownerWantsIt = on
        ownerOn = on
        if on, status == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        update(client: client ?? AppModel.shared.client, wanted: macFeature, active: true)
    }

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
        manager.stopMonitoringVisits()
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

    /// Arrived at or left a place: always worth sending (the place itself, when it happened).
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let left = visit.departureDate != .distantFuture
        let at = left ? visit.departureDate : visit.arrivalDate
        guard at != .distantPast, at.timeIntervalSinceNow > -47 * 3600 else { return }
        let fix = LocationPolicy.Fix(lat: visit.coordinate.latitude, lng: visit.coordinate.longitude,
                                     accuracy: visit.horizontalAccuracy, at: at)
        Task { @MainActor in await self.consider(fix, visit: left ? "떠남" : "도착") }
    }

    private func consider(_ fix: LocationPolicy.Fix, visit: String? = nil) async {
        let wasOpening = opening
        opening = false
        guard Self.macWantsIt, !sending, visit != nil || LocationPolicy.shouldSend(fix, last: lastSent, opening: wasOpening) else { return }
        // A relaunch for a move in the background: the model may not have a client yet.
        guard let client = client ?? AppModel.shared.client else { return }
        sending = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "send-location")
        defer { UIApplication.shared.endBackgroundTask(task); sending = false }
        do {
            if Self.appRoute, visit == nil {
                try await client.reportLocation(lat: fix.lat, lng: fix.lng, accuracyM: fix.accuracy)
            } else {
                try await client.ingest([PhoneSignals.location(lat: fix.lat, lng: fix.lng, accuracy: fix.accuracy, label: visit, at: fix.at)])
            }
            // Woken for a move: a good moment for the other signals too.
            await AppModel.shared.signals.check()
            lastSent = fix
            lastSentAt = Date()
        } catch {
            // Not sent: the next fix (or the next 20-minute tick) tries again.
        }
    }
}
