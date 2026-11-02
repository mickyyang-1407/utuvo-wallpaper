import CoreLocation
import Foundation

/// 日出日落要用的位置：使用者選「依日出日落」時讀一次目前位置、存成座標（只存在這支 iPhone）。
/// 捷徑的日出／日落自動化用的是手機實際位置，App 也用同一個位置才對得上。
@MainActor
final class LocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: Status = .idle
    enum Status: Equatable { case idle, locating, saved, denied, failed }

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// 已經允許過才更新（不跳權限視窗）：App 打開或進設定時呼叫，讓位置跟著人走。
    func refreshIfAuthorized() {
        guard DynamicTiming.load() == .solar else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            status = .locating
            manager.requestLocation()
        default: break
        }
    }

        func fetch() {
        status = .locating
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: status = .denied
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let state = manager.authorizationStatus
        Task { @MainActor in
            guard self.status == .locating else { return }
            switch state {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: self.status = .denied
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // 只留兩位小數（約 1 公里），日出日落夠準，也不存精確位置。
        let rounded = Coordinate(latitude: (location.coordinate.latitude * 100).rounded() / 100,
                                 longitude: (location.coordinate.longitude * 100).rounded() / 100)
        Task { @MainActor in
            Coordinate.save(rounded)
            self.status = .saved
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.status = .failed }
    }
}
