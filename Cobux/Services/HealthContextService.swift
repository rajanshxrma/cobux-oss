import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Reads the small slice of Apple Health that gives a journal entry physical
/// context: did you meditate today, and how did you sleep last night.
///
/// Rajan's reminder was "Cobux journal meditation to be also considered with
/// whoop". His WHOOP writes both of these into Apple Health (7 meditation
/// sessions in the last 14 days at the time this shipped), so the data is
/// already on the device — Cobux simply had no way to see it. Reading HealthKit
/// on-device is the correct path and the only one that works: the WHOOP numbers
/// on his Mac live in cadence's local SQLite store, which an iOS app can never
/// reach.
///
/// Deliberately narrow, for privacy and for blast radius: **read-only**, only
/// `mindfulSession` and `sleepAnalysis`, never written back, never uploaded,
/// and never included in the backup export. It is context shown beside your own
/// writing, not another dataset the app starts owning.
///
/// Every failure path returns `nil` rather than throwing or blocking. HealthKit
/// is unavailable on some devices, the user can decline (or grant only part of
/// the request, which Apple deliberately makes indistinguishable from "no
/// data"), and none of that is an error worth interrupting someone who sat down
/// to write. Same graceful-degradation contract as `UbiquityContainer` and
/// `CrashReportCollector`.
///
/// **LIVE as of 2.5.18** -- Rajan enabled the HealthKit capability on the App
/// ID himself (2026-08-23) and `com.apple.developer.healthkit` is now in
/// `Cobux.entitlements`. This shipped dormant for exactly one build first,
/// because adding the entitlement before the capability exists fails the build
/// outright ("Provisioning profile ... doesn't include the HealthKit
/// capability") and enabling a capability is an account-level change that
/// isn't mine to make autonomously.
///
/// Note `healthkit-access` is deliberately absent: that key is only for
/// clinical health records and is rejected as invalid otherwise -- including
/// it was the second of the two build errors on the first attempt.
struct HealthContext: Equatable {
    /// Minutes of mindfulness logged today. `nil` when unreadable/unpermitted;
    /// `0` genuinely means "none today", which is a different, useful fact.
    var mindfulMinutesToday: Int?
    /// Hours of sleep in the most recent overnight, one decimal.
    var sleepHoursLastNight: Double?

    var isEmpty: Bool { mindfulMinutesToday == nil && sleepHoursLastNight == nil }

    /// One quiet line for the compose screen -- "18 min mindful · 8.7h sleep".
    /// Returns nil when there's genuinely nothing to say, so the caller can omit
    /// the row entirely rather than render an empty shell.
    var summaryLine: String? {
        var parts: [String] = []
        if let m = mindfulMinutesToday, m > 0 { parts.append("\(m) min mindful") }
        if let h = sleepHoursLastNight { parts.append(String(format: "%.1fh sleep", h)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum HealthContextService {
    #if canImport(HealthKit)
    private static let store = HKHealthStore()

    private static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let mindful = HKObjectType.categoryType(forIdentifier: .mindfulSession) {
            types.insert(mindful)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }
    #endif

    /// True only where HealthKit actually exists (it's absent on iPad/Mac
    /// Catalyst builds of some configurations), so callers can hide the whole
    /// feature rather than surface a control that can never work.
    /// Whether the user has opted in from Settings. Defaults to false: HealthKit access is
    /// something to be asked for once, in context, not assumed.
    static let enabledKey = "cobux.health.contextEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var isAvailable: Bool {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    /// Asks for read access. Safe to call repeatedly -- iOS shows the sheet only
    /// once and silently succeeds afterwards. Called when the user opts in from
    /// Settings, never at launch: a permission prompt on first run, before any
    /// context has been explained, is how people learn to tap Deny.
    static func requestAuthorization() async -> Bool {
        #if canImport(HealthKit)
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Today's mindful minutes + last night's sleep. Never throws; unreadable
    /// values simply stay `nil`.
    static func currentContext() async -> HealthContext {
        #if canImport(HealthKit)
        guard isAvailable else { return HealthContext() }
        async let mindful = mindfulMinutesToday()
        async let sleep = sleepHoursLastNight()
        return HealthContext(mindfulMinutesToday: await mindful, sleepHoursLastNight: await sleep)
        #else
        return HealthContext()
        #endif
    }

    #if canImport(HealthKit)
    private static func mindfulMinutesToday() async -> Int? {
        guard let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) else { return nil }
        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)
        guard let samples = await samples(of: type, predicate: predicate, limit: 200) else { return nil }
        // Mindfulness is stored as intervals, so the meaningful number is total
        // duration, not sample count -- three 6-minute sits is 18 minutes, and
        // reporting "3" would be nonsense next to a single 20-minute session.
        let seconds = samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return Int((seconds / 60).rounded())
    }

    private static func sleepHoursLastNight() async -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        // 36h window: catches last night whether he woke at 6am or slept in,
        // and whether it's currently morning or late evening.
        let start = Date.now.addingTimeInterval(-36 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)
        guard let samples = await samples(of: type, predicate: predicate, limit: 400) else { return nil }

        // Only genuinely-asleep stages. `inBed` overlaps them and would double
        // count; `awake` is time in bed not sleeping. WHOOP writes the staged
        // values, so this matches what its own app reports.
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let asleep = samples.filter { asleepValues.contains($0.value) }
        guard !asleep.isEmpty else { return nil }

        // Union the intervals rather than summing them: multiple sources
        // (WHOOP + the phone itself) can both write overlapping samples for the
        // same night, and a naive sum reports twelve hours of sleep for eight.
        let merged = mergedDuration(asleep.map { ($0.startDate, $0.endDate) })
        let hours = merged / 3600
        return hours > 0 ? (hours * 10).rounded() / 10 : nil
    }

    /// Total covered time of a set of possibly-overlapping intervals.
    private static func mergedDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (start: Date, end: Date)?
        for (start, end) in sorted {
            guard var open = current else {
                current = (start, end)
                continue
            }
            if start <= open.end {
                open.end = max(open.end, end)
                current = open
            } else {
                total += open.end.timeIntervalSince(open.start)
                current = (start, end)
            }
        }
        if let open = current { total += open.end.timeIntervalSince(open.start) }
        return total
    }

    private static func samples(
        of type: HKCategoryType, predicate: NSPredicate, limit: Int
    ) async -> [HKCategorySample]? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: limit, sortDescriptors: nil
            ) { _, results, _ in
                // Errors and denials both land here as nil/empty -- and are
                // treated identically on purpose, because Apple deliberately
                // makes "denied" indistinguishable from "no data" for reads.
                continuation.resume(returning: results as? [HKCategorySample])
            }
            store.execute(query)
        }
    }
    #endif
}
