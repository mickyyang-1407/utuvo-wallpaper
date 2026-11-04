import Foundation

// 把 Mac／iPhone 共用的提示詞資料與標準答案匯出成 JSON，給 Android 用。
// 資料（data.json）打包進 App；標準答案（golden.json）給 JVM 測試逐字比對。
// 執行：bash android/tools/export/export.sh

Localization.sourceOnly = true

func pairs(_ list: [(zh: String, en: String)]) -> [[String]] { list.map { [$0.zh, $0.en] } }

let templates: [[String: Any]] = PromptTemplate.shared.map { t in
    var d: [String: Any] = ["id": t.id, "title": t.title, "category": t.category, "style": t.style,
                            "subjects": t.subjects, "palettes": t.palettes, "representational": t.representational]
    if let local = t.local { d["local"] = local }
    return d
}
var ideas: [String: Any] = [:]
for (key, list) in PromptInspiration.ideas { ideas[key] = pairs(list) }

let utc = TimeZone(identifier: "UTC")!
var tz: [String: [Double]] = [:]
for id in TimeZone.knownTimeZoneIdentifiers {
    guard let zone = TimeZone(identifier: id) else { continue }
    let c = Coordinate.estimate(for: zone)
    // 只存表內城市（表外的 Kotlin 端照同一規則用 UTC 偏移推）。
    if !(c.latitude == 30 && c.longitude == max(-180, min(180, Double(zone.secondsFromGMT()) / 3600 * 15))) {
        tz[id] = [c.latitude, c.longitude]
    }
}

let data: [String: Any] = [
    "templates": templates,
    "lights": PromptTemplate.lights,
    "compositions": PromptTemplate.compositions,
    "mixedStyleTemplates": DailyPlan.mixedStyleTemplates.sorted(),
    "ideas": ideas,
    "details": pairs(PromptInspiration.details),
    "autoSubjects": DynamicAutoPlanner.subjects.map { ["id": $0.id, "zh": $0.zh, "en": $0.en, "winterOnly": $0.winterOnly] as [String: Any] },
    "autoStyles": pairs(DynamicAutoPlanner.styles),
    "autoWeathers": pairs(DynamicAutoPlanner.weathers),
    "timeZoneCities": tz,
]

// ---------- 標準答案 ----------
let days = ["2026-01-01", "2026-02-28", "2026-03-01", "2026-06-15", "2026-11-03", "2026-12-31", "2027-07-04", "2030-10-10", "bad-day"]
let categories = DailyRecipe.categories
var recipes: [(String, DailyRecipe)] = [("all", DailyRecipe())]
for c in categories { var r = DailyRecipe(); r.setCategory(c, on: true); recipes.append(("cat-" + c, r)) }
var mixed = DailyRecipe(); mixed.setCategory("自然", on: true); mixed.setCategory("純色", on: true); mixed.setCategory("城市", on: true)
recipes.append(("mixed", mixed))
var ideaRecipe = mixed; ideaRecipe.idea = "  一隻在窗邊打盹的橘貓  "
recipes.append(("idea", ideaRecipe))
var ideaAll = DailyRecipe(); ideaAll.idea = "a lighthouse in the rain"
recipes.append(("idea-all", ideaAll))

var plans: [[String: Any]] = []
for day in days {
    for (name, recipe) in recipes {
        for salt in ["", "abc", "5F2B7E0A-1111-4222-8333-944444444444"] {
            if salt != "" && name != "all" && name != "idea" { continue }
            let plan = DailyPlan.make(day: day, count: 10, recipe: recipe, salt: salt)
            plans.append(["day": day, "recipe": name, "styles": recipe.styles, "idea": recipe.idea, "salt": salt,
                          "plan": plan.map { ["templateID": $0.templateID, "slug": $0.slug, "prompt": $0.prompt,
                                              "portrait": PortraitPrompt.convert($0.prompt)] }])
        }
    }
}

var hashes: [[String: String]] = []
for text in ["", "a", "nature-dawn", "2026-11-03#0", "日夜", "ai-2026-W45#12#lighthouse"] + PromptTemplate.shared.map(\.id) {
    hashes.append(["text": text, "hash": String(DynamicAutoPlanner.stableHash(text))])
}
var dayIndexes: [[String: Any]] = days.map { ["day": $0, "index": DailyPlan.dayIndex($0)] }

// AI 靈感：固定亂數序列
var inspirations: [[String: Any]] = []
let catSets: [[String]] = [[], ["自然"], ["純色", "漸層"], ["城市", "動物", "3D"], categories]
for set in catSets {
    for chinese in [true, false] {
        for seed in [0, 1, 7, 12345, 999_999, 424_242] {
            var rolls: [Int] = []
            var s = UInt64(seed + 1)
            let current = chinese ? "清晨霧氣中的竹林小徑" : ""
            let text = PromptInspiration.pick(categories: set, current: current, chinese: chinese) {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let v = Int((s >> 33) % 1_000_000)
                rolls.append(v)
                return v
            }
            inspirations.append(["categories": set, "chinese": chinese, "current": current, "rolls": rolls, "result": text])
        }
    }
}

// AI 自動挑題
var autoPicks: [[String: Any]] = []
let seasons: [(String, DynamicAutoPlanner.Season)] = [("spring", .spring), ("summer", .summer), ("autumn", .autumn), ("winter", .winter)]
let periods = ["2026-11-03", "2026-11-04", "2026-W45", "2026-W46", "2027-01-01", "manual"]
for period in periods {
    for (sname, season) in seasons {
        for recent in [[], ["lake-cabin", "lighthouse"], DynamicAutoPlanner.subjects.prefix(6).map(\.id)] {
            for salt in [0, 1_793_711_352] {
                for chinese in [true, false] {
                    let r = DynamicAutoPlanner.pick(period: period, salt: salt, season: season, recent: recent, chinese: chinese)
                    autoPicks.append(["period": period, "season": sname, "recent": recent, "salt": salt, "chinese": chinese,
                                      "subject": r.subject, "prompt": r.prompt,
                                      "sceneID": "ai-\(period)-\(String(DynamicAutoPlanner.stableHash("\(period)#\(salt)#\(r.subject)") % 1_000_000))"])
                }
            }
        }
    }
}

// 期別與季節
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Taipei")!
var periodCases: [[String: Any]] = []
for ts in [1_767_196_800.0, 1_772_000_000, 1_793_711_352, 1_798_675_200, 1_800_000_000, 1_830_000_000, 1_609_459_200, 1_704_067_199] {
    let d = Date(timeIntervalSince1970: ts)
    periodCases.append(["epoch": ts, "zone": "Asia/Taipei",
                        "daily": DynamicAutoPlanner.period(for: d, frequency: .daily, calendar: cal)!,
                        "weekly": DynamicAutoPlanner.period(for: d, frequency: .weekly, calendar: cal)!,
                        "season": "\(DynamicAutoPlanner.season(for: d, calendar: cal))",
                        "seasonSouth": "\(DynamicAutoPlanner.season(for: d, calendar: cal, southern: true))"])
}

// 日出日落
var solar: [[String: Any]] = []
let places: [(String, Double, Double)] = [("Asia/Taipei", 25.03, 121.56), ("Europe/London", 51.51, -0.13),
    ("America/New_York", 40.71, -74.01), ("Australia/Sydney", -33.87, 151.21), ("Europe/Oslo", 59.91, 10.75),
    ("Europe/Helsinki", 69.65, 18.96)]
for (zone, lat, lon) in places {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!
    for (y, m, d) in [(2026, 1, 1), (2026, 3, 8), (2026, 3, 29), (2026, 6, 21), (2026, 9, 23), (2026, 11, 1), (2026, 11, 3), (2026, 12, 21)] {
        let date = c.date(from: DateComponents(year: y, month: m, day: d, hour: 8))!
        let r = SolarCalculator.sunriseSunset(on: date, at: Coordinate(latitude: lat, longitude: lon), calendar: c)
        var row: [String: Any] = ["zone": zone, "lat": lat, "lon": lon, "date": String(format: "%04d-%02d-%02d", y, m, d)]
        if let r { row["sunrise"] = r.sunrise; row["sunset"] = r.sunset }
        solar.append(row)
    }
}

let scene = ["base": ScenePrompt.base("一間雨天的咖啡廳，窗外是街道，手繪動畫背景", canvas: .phone),
             "dawn": ScenePrompt.relight("dawn", canvas: .phone), "day": ScenePrompt.relight("day", canvas: .phone),
             "dusk": ScenePrompt.relight("dusk", canvas: .phone), "night": ScenePrompt.relight("night", canvas: .phone)]

let golden: [String: Any] = ["plans": plans, "hashes": hashes, "dayIndexes": dayIndexes, "inspirations": inspirations,
                             "autoPicks": autoPicks, "periods": periodCases, "solar": solar, "scene": scene,
                             "sceneInput": "一間雨天的咖啡廳，窗外是街道，手繪動畫背景"]

func write(_ object: Any, _ path: String) {
    let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    try! json.write(to: URL(fileURLWithPath: path))
}
write(data, CommandLine.arguments[1])
write(golden, CommandLine.arguments[2])
print("templates \(templates.count), plans \(plans.count), autoPicks \(autoPicks.count), solar \(solar.count), inspirations \(inspirations.count)")
