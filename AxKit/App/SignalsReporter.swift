import AxKitCore
import Foundation
import HealthKit
import Observation
import UIKit

/// 휴대폰 신호 the app sends by itself (besides location, see `LocationReporter`): the battery when it runs low and
/// yesterday's steps once a day, to `POST /m/v1/ingest`. Each is the owner's own switch, off until turned on.
/// iOS gives an app no battery or step events while it is closed, so both are checked when the app opens, while it
/// is open, and when a move wakes it in the background.
@MainActor @Observable
final class SignalsReporter {
    private(set) var batteryOn = UserDefaults.standard.bool(forKey: "signals.battery")
    private(set) var stepsOn = UserDefaults.standard.bool(forKey: "signals.steps")
    private(set) var lastSent: [PhoneSignals.Kind: Date] = [:]
    /// The owner said no to 건강 (or this device has no Health data).
    private(set) var stepsBlocked = false
    var stepsAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let health = HKHealthStore()
    private var observing = false
    private var checking = false

    private var batteryLastLevel: Int? {
        get { UserDefaults.standard.object(forKey: "signals.battery.last") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "signals.battery.last") }
    }
    private var stepsLastDay: String? {
        get { UserDefaults.standard.string(forKey: "signals.steps.day") }
        set { UserDefaults.standard.set(newValue, forKey: "signals.steps.day") }
    }

    init() {
        for kind in PhoneSignals.Kind.allCases {
            if let at = UserDefaults.standard.object(forKey: "signals.\(kind.rawValue).at") as? Date { lastSent[kind] = at }
        }
        if batteryOn { watchBattery() }
    }

    func setBattery(_ on: Bool) {
        batteryOn = on
        UserDefaults.standard.set(on, forKey: "signals.battery")
        if on { watchBattery(); Task { await checkBattery() } } else { UIDevice.current.isBatteryMonitoringEnabled = false; batteryLastLevel = nil }
    }

    func setSteps(_ on: Bool) {
        stepsOn = on
        UserDefaults.standard.set(on, forKey: "signals.steps")
        guard on else { return }
        Task {
            await askHealth()
            await checkSteps()
        }
    }

    /// On open and when a move wakes the app.
    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await checkBattery()
        await checkSteps()
    }

    // MARK: battery

    private func watchBattery() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        guard !observing else { return }
        observing = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.checkBattery() }
            }
        }
    }

    private func checkBattery() async {
        guard batteryOn else { return }
        let device = UIDevice.current
        guard device.batteryLevel >= 0 else { return } // the simulator and unknown states report -1
        let level = Int((device.batteryLevel * 100).rounded())
        let charging = device.batteryState == .charging || device.batteryState == .full
        batteryLastLevel = PhoneSignals.Battery.remembered(level: level, charging: charging, lastSent: batteryLastLevel)
        guard let send = PhoneSignals.Battery.toSend(level: level, charging: charging, lastSent: batteryLastLevel) else { return }
        if await post([PhoneSignals.battery(level: send, at: Date())], .battery) { batteryLastLevel = send }
    }

    // MARK: steps

    private var stepType: HKQuantityType { HKQuantityType(.stepCount) }

    private func askHealth() async {
        guard stepsAvailable else { stepsBlocked = true; return }
        do {
            try await health.requestAuthorization(toShare: [], read: [stepType])
            stepsBlocked = false
        } catch {
            stepsBlocked = true
        }
    }

    private func checkSteps() async {
        guard stepsOn, stepsAvailable, let day = PhoneSignals.Steps.dayToSend(lastSentDay: stepsLastDay) else { return }
        guard let count = await steps(on: day) else { return }
        if await post([PhoneSignals.steps(count, date: day, at: Date())], .steps) { stepsLastDay = day }
    }

    /// The day's total (Seoul), or nil when Health has nothing for it (not allowed, or no samples).
    private func steps(on day: String) async -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Format.seoul
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let start = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { done in
            let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                done.resume(returning: stats?.sumQuantity().map { Int($0.doubleValue(for: .count()).rounded()) })
            }
            health.execute(query)
        }
    }

    // MARK: sending

    private func post(_ items: [[String: Any]], _ kind: PhoneSignals.Kind) async -> Bool {
        guard let client = AppModel.shared.client else { return false }
        let task = UIApplication.shared.beginBackgroundTask(withName: "send-signal")
        defer { UIApplication.shared.endBackgroundTask(task) }
        do {
            try await client.ingest(items)
            let now = Date()
            lastSent[kind] = now
            UserDefaults.standard.set(now, forKey: "signals.\(kind.rawValue).at")
            return true
        } catch {
            return false // tried again on the next open or reading
        }
    }

    /// Clears everything when the phone is unpaired.
    func reset() {
        setBattery(false)
        setSteps(false)
        for kind in PhoneSignals.Kind.allCases { UserDefaults.standard.removeObject(forKey: "signals.\(kind.rawValue).at") }
        lastSent = [:]
        stepsLastDay = nil
    }
}
