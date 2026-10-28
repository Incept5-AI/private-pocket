import CoreLocation
import MapKit

/// Where a recording was made. The Pocket has no GPS, so this is the phone's
/// position when the recording started (precise) or when it was downloaded
/// shortly afterwards (`approximate`).
struct Place: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var name: String?
    var approximate = false

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    var coordinateText: String { String(format: "%.5f, %.5f", latitude, longitude) }
    var label: String { name ?? coordinateText }
    var mapsURL: URL { URL(string: "maps://?ll=\(latitude),\(longitude)&q=Recording")! }
}

/// Phone location for tagging recordings. Coordinates come from the phone's own
/// location services; turning them into a place name needs Apple's geocoder,
/// which is the one network request the app makes, and only if enabled in Settings.
@MainActor
final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Learned from the manager's own callback once it exists.
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private var made: CLLocationManager?
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    /// Location requests made, so a timeout only ends the one it was set for.
    private var asked = 0

    /// Made on first use, never while the app is being created: making one, and reading its
    /// status, wait on the location service, and at launch that wait can outlast the
    /// watchdog, which then kills the app.
    private var manager: CLLocationManager {
        if let m = made { return m }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        made = m
        return m
    }

    /// Places captured when a recording started, keyed by its file name, until the
    /// recording is downloaded. Persisted so a later sync still finds them.
    private var pending: [String: Place] {
        get {
            (UserDefaults.standard.data(forKey: "pendingPlaces"))
                .flatMap { try? JSONDecoder().decode([String: Place].self, from: $0) } ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "pendingPlaces") }
    }

    /// Makes the manager after launch, so Settings can show what was allowed.
    func prepare() {
        _ = manager
    }

    var enabled: Bool { Prefs.tagLocation }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Records where the phone is now for a recording that has just started.
    func recordingStarted(_ name: String) {
        guard enabled else { return }
        Task {
            guard let place = await currentPlace(approximate: false) else { return }
            var p = pending
            p[name] = place
            // Drop anything older than a week that was never downloaded.
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            p = p.filter { (PocketTime.parse($0.key) ?? .distantPast) > cutoff }
            pending = p
        }
    }

    /// The place for a recording being saved: the one captured at its start, or,
    /// if it finished in the last 15 minutes, where the phone is now (approximate).
    func place(for name: String, seconds: Int?) async -> Place? {
        guard enabled else { return nil }
        if let p = pending[name] {
            var all = pending
            all[name] = nil
            pending = all
            return p
        }
        guard let start = PocketTime.parse(name) else { return nil }
        let end = start.addingTimeInterval(TimeInterval(seconds ?? 0))
        guard Date().timeIntervalSince(end) < 15 * 60 else { return nil }
        return await currentPlace(approximate: true)
    }

    func currentPlace(approximate: Bool) async -> Place? {
        guard let loc = await currentLocation() else { return nil }
        var place = Place(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                          accuracy: loc.horizontalAccuracy, approximate: approximate)
        place.name = await Self.name(for: loc)
        return place
    }

    /// Reverse geocodes with Apple's service, if the user allows it.
    static func name(for loc: CLLocation) async -> String? {
        guard Prefs.lookUpPlaceNames, let req = MKReverseGeocodingRequest(location: loc),
              let item = try? await req.mapItems.first else { return nil }
        let city = item.addressRepresentations?.cityName
        let name = item.name ?? item.address?.shortAddress
        switch (name, city) {
        case let (n?, c?) where !n.contains(c): return "\(n), \(c)"
        case let (n?, _): return n
        case let (nil, c): return c
        }
    }

    private func currentLocation() async -> CLLocation? {
        // A fix from the last two minutes is good enough and works in the background.
        if let l = manager.location, -l.timestamp.timeIntervalSinceNow < 120, l.horizontalAccuracy < 200 { return l }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        case .notDetermined: requestPermission(); return manager.location
        default: return nil
        }
        let l = await withCheckedContinuation { c in
            waiting.append(c)
            guard waiting.count == 1 else { return }
            asked += 1
            let mine = asked
            manager.requestLocation()
            // No answer in ten seconds (in the background there may be none): the recording is
            // saved without a place rather than waiting on one.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.asked == mine, !self.waiting.isEmpty else { return }
                self.finish(nil)
            }
        }
        return l ?? manager.location
    }

    private func finish(_ l: CLLocation?) {
        let w = waiting
        waiting = []
        w.forEach { $0.resume(returning: l) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { finish(locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { authorization = manager.authorizationStatus }
    }
}
