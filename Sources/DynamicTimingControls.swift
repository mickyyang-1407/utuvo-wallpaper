import SwiftUI

/// 日夜場景的切換方式：固定時間／日出日落／跟系統淺深色。位置預設依時區推估，可自訂座標。
struct DynamicTimingControls: View {
    var onChange: () -> Void
    @State private var timing = DynamicTiming.load()
    @State private var latitude: String
    @State private var longitude: String
    @State private var usingTimeZone: Bool
    @State private var invalid = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let (coordinate, fromTimeZone) = Coordinate.load()
        _latitude = State(initialValue: String(format: "%.2f", coordinate.latitude))
        _longitude = State(initialValue: String(format: "%.2f", coordinate.longitude))
        _usingTimeZone = State(initialValue: fromTimeZone)
    }

    var body: some View {
        Picker("切換方式", selection: Binding(get: { timing }, set: { setTiming($0) })) {
            ForEach(DynamicTiming.allCases) { Text($0.title).tag($0) }
        }
        if timing == .solar {
            let schedule = DynamicSchedule.load()
            Text("今天：清晨 \(schedule.startTime(of: .dawn))、白天 \(schedule.startTime(of: .day))、黃昏 \(schedule.startTime(of: .dusk))、夜晚 \(schedule.startTime(of: .night))")
                .font(.caption).monospacedDigit().foregroundStyle(WallpaperPalette.secondaryText)
            HStack {
                TextField("緯度", text: $latitude).frame(width: 90)
                TextField("經度", text: $longitude).frame(width: 90)
                Button("儲存位置") { saveLocation() }
                if !usingTimeZone { Button("改回依時區") { Coordinate.save(nil); load(); onChange() } }
            }
            Text(invalid ? L("座標格式不對：緯度 −90～90、經度 −180～180。")
                 : usingTimeZone ? L("目前依時區推估位置，誤差通常幾分鐘；要更準可填自己的座標。") : L("使用自訂座標。"))
                .font(.caption).foregroundStyle(invalid ? .orange : WallpaperPalette.secondaryText)
        } else if timing == .appearance {
            Text("系統是淺色顯示白天、深色顯示夜晚；系統設為「自動」時會跟著日落切換。")
                .font(.caption).foregroundStyle(WallpaperPalette.secondaryText)
        }
    }

    private func load() {
        timing = DynamicTiming.load()
        let (coordinate, fromTimeZone) = Coordinate.load()
        usingTimeZone = fromTimeZone
        latitude = String(format: "%.2f", coordinate.latitude)
        longitude = String(format: "%.2f", coordinate.longitude)
        invalid = false
    }

    private func setTiming(_ value: DynamicTiming) {
        timing = value
        AppDefaults.shared.set(value.rawValue, forKey: DynamicTiming.defaultsKey)
        AppDefaults.shared.synchronize()
        onChange()
    }

    private func saveLocation() {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon) else { invalid = true; return }
        Coordinate.save(Coordinate(latitude: lat, longitude: lon))
        load()
        onChange()
    }
}
