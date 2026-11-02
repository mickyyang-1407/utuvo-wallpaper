import Foundation

/// 一組原創風格提示詞模板。
///
/// 設計原則：
/// - 只描述「風格與主題」，不模仿任何在世畫家或特定藝術家的風格。
/// - 每張圖 16:9、純圖像、無文字、無浮水印。
/// - 風格（style）固定，主題（subjects）與配色（palettes）每天換，同一風格才不會天天長一樣。
struct PromptTemplate: Identifiable, Hashable, Sendable {
    let id: String
    /// 中文介面顯示的名稱
    let title: String
    /// 分類
    let category: String
    /// 畫風描述（英文，模型效果較穩）
    let style: String
    /// 可輪替的主題
    let subjects: [String]
    /// 可輪替的配色
    let palettes: [String]
    /// 寫實或具象畫面才加光線描述；抽象、宇宙不加。
    var representational = true

    /// 預設組合（第一個主題、第一組配色）。
    var prompt: String { compose(subject: subjects[0], palette: palettes[0], light: nil, composition: nil) }

    func compose(subject: String, palette: String, light: String?, composition: String?) -> String {
        var parts = [style, "Subject: \(subject)", "Palette: \(palette)"]
        if let light, representational { parts.append(light) }
        if let composition { parts.append(composition) }
        parts.append("wide 16:9 desktop wallpaper, no text, no watermark, no logos")
        return parts.joined(separator: ". ") + "."
    }

    static let lights = [
        "soft early morning light", "clear midday light", "warm late afternoon light",
        "golden hour backlight", "overcast diffused light", "blue hour after sunset",
    ]
    static let compositions = [
        "wide open composition with generous negative space", "low horizon with a large sky",
        "subject placed off-center on the right third", "subject placed off-center on the left third",
        "layered foreground, middle ground and distance", "calm symmetrical composition",
    ]

    static let shared: [PromptTemplate] = [
        PromptTemplate(
            id: "nature-dawn", title: "自然 · 自然風景", category: "自然",
            style: "Natural landscape photograph, photographic realism, ultra detailed, delicate atmospheric depth, no people",
            subjects: [
                "layered alpine ridgelines with low mist drifting between them",
                "a glacier-fed lake below granite peaks", "rolling green hills with scattered lone trees",
                "a coastal cliff path above a turquoise sea", "a quiet birch forest in light fog",
                "volcanic black-sand beach with sea stacks", "a high desert plateau with wind-carved rocks",
                "a wide river delta seen from a hilltop", "a waterfall in a mossy gorge", "a field of wildflowers below distant peaks", "salt flats reflecting the sky",
            ],
            palettes: ["cool blue shadows warming to pale gold", "fresh greens and soft sky blue",
                       "muted earth tones with slate grey", "silver mist and deep evergreen"]),
        PromptTemplate(
            id: "minimal-paper", title: "極簡 · 紙雕極簡", category: "極簡",
            style: "Minimalist paper-craft scene, soft off-white paper texture, layered cut-paper shapes, subtle grain, flat graphic design, vast negative space, elegant and calm",
            subjects: [
                "one distant mountain silhouette", "a single sailboat on a flat sea", "a lone tree on a gentle hill",
                "a crescent moon over rolling dunes", "a small house beside a curved road", "three stacked cloud shapes over water",
                "a paper sun setting behind layered waves", "a lighthouse on a tiny island", "a single hot-air balloon over hills", "a winding river through flat fields",
            ],
            palettes: ["muted teal and pale ochre", "dusty pink and warm sand", "sage green and cream",
                       "navy and soft apricot", "charcoal and pale gold"]),
        PromptTemplate(
            id: "abstract-flow", title: "抽象 · 流動光帶", category: "抽象",
            style: "Abstract generative art, smooth gradient mesh, silky curved bands with soft blur transitions, luminous depth, no hard edges",
            subjects: [
                "flowing ribbons of light", "a slow spiral of translucent glass layers", "overlapping soft circles like aurora",
                "a single wave of liquid silk", "folded light planes in space", "drifting smoke-like color veils", "a glowing ring of soft light", "stacked translucent glass panes", "rippling liquid metal surface", "soft bokeh orbs floating in depth",
            ],
            palettes: ["deep indigo, violet and warm amber", "emerald, teal and cream", "coral, peach and lilac",
                       "graphite, silver and ice blue", "magenta, orange and plum"],
            representational: false),
        PromptTemplate(
            id: "illustration-dusk", title: "插畫 · 插畫街景", category: "插畫",
            style: "Editorial illustration, flat vector shapes with subtle grain texture, limited palette, charming and calm",
            subjects: [
                "a quiet city corner with warm shop windows and bicycles", "a rooftop garden above a dense city",
                "a small bookstore street after rain", "a tram crossing a hillside town", "a riverside market packing up",
                "a lighthouse keeper's cottage by the sea", "a night bus stop under a streetlight", "a seaside cafe terrace in the morning", "a mountain cable car station", "a flower market under striped awnings",
            ],
            palettes: ["coral, indigo and cream", "mint, mustard and navy", "rose, teal and sand",
                       "tomato red, olive and ivory"]),
        PromptTemplate(
            id: "cosmic-nebula", title: "宇宙 · 深空", category: "宇宙",
            style: "Astrophotography realism with artistic color grading, very high detail, near-black sky, faint starlight, no planets in the center",
            subjects: [
                "a deep space nebula with dust lanes", "a spiral galaxy seen at an angle", "a dense star cluster with glowing gas",
                "the Milky Way core above a dark horizon", "a ring of glowing gas around a dying star", "comet trail crossing a star field", "a dark nebula silhouetted against bright gas", "two galaxies merging", "an aurora over a planet horizon seen from orbit",
            ],
            palettes: ["teal and magenta clouds", "gold and deep blue", "crimson and violet", "pale cyan and silver"],
            representational: false),
        PromptTemplate(
            id: "botanical-macro", title: "自然 · 自然微距", category: "自然",
            style: "Macro nature photograph, intricate detail, soft bokeh background, natural color science",
            subjects: [
                "a single backlit leaf with glowing veins", "dew droplets on a spider web", "a fern frond unfurling",
                "the center of a sunflower", "frost crystals on a window", "moss and tiny mushrooms on bark",
                "a dragonfly wing", "ripples on a still pond surface", "a snail shell spiral", "pollen on a bee's leg", "soap bubble interference colors",
            ],
            palettes: ["emerald against dark green bokeh", "amber and honey tones", "icy blue and white",
                       "violet and soft pink"]),
        PromptTemplate(
            id: "watercolor-meadow", title: "水彩 · 水彩風景", category: "水彩",
            style: "Original watercolor painting, transparent washes, visible cold-pressed paper texture, loose edges, spacious composition, quiet and inviting",
            subjects: [
                "rolling meadows with a narrow winding path", "a harbor with small fishing boats", "an old stone farmhouse in lavender fields",
                "a canal town with arched bridges", "a mountain lake with reflections", "a seaside village on a hill",
                "an orchard in blossom", "a quiet beach with a striped umbrella", "a misty forest stream", "a snowy village street",
            ],
            palettes: ["sage green, honey and dusty rose", "cobalt, ochre and white", "lavender, olive and peach",
                       "teal, rust and cream"]),
        PromptTemplate(
            id: "architecture-arcade", title: "建築 · 建築光影", category: "建築",
            style: "Architectural photograph, precise material detail, restrained composition, long geometric shadows, no people",
            subjects: [
                "a sunlit sandstone arcade with repeated rounded arches", "a spiral concrete staircase seen from above",
                "a minimalist white courtyard with a single olive tree", "a brutalist library facade",
                "a glass atrium with a curved steel roof", "a terracotta-tiled Mediterranean alley",
                "a Japanese timber corridor around a garden", "a curved white museum ramp", "a red brick factory turned gallery", "a modern pavilion over a reflecting pool",
            ],
            palettes: ["warm limestone and terracotta", "white, grey and sky blue", "raw concrete and green plants",
                       "pale pink stucco and deep shadow"]),
        PromptTemplate(
            id: "animation-coast", title: "動畫 · 手繪動畫", category: "動畫",
            style: "Original hand-drawn animation background, delicate painted textures, expressive clean linework, gentle nostalgic atmosphere, no characters",
            subjects: [
                "a tiny seaside railway station above a turquoise bay", "a hillside town with stairs and laundry lines",
                "a countryside bus stop under huge summer clouds", "a forest shrine path with lanterns",
                "a harbor town at festival time", "a schoolyard after the bell under cherry trees",
                "a rooftop water tower over the city", "a lakeside camping spot at dusk", "a narrow alley of noodle shops", "a sunflower field beside a railway",
            ],
            palettes: ["muted cream and coral", "summer blue and grass green", "sunset orange and purple",
                       "soft pink and pale mint"]),
        PromptTemplate(
            id: "gradient-tide", title: "抽象 · 柔和漸層", category: "抽象",
            style: "Minimal abstract color-field wallpaper, extremely smooth transitions, subtle film grain",
            subjects: [
                "layered horizontal color fields like a tide", "a soft radial glow fading to the edges",
                "two overlapping color blurs", "a diagonal gradient band like sunset haze", "a calm vertical aurora curtain", "a soft ring of light on a dark field", "four quiet color blocks blending", "a wavy horizon gradient",
            ],
            palettes: ["deep ocean blue through teal to pale sand", "rose to lilac to midnight", "lime to aqua to navy",
                       "peach to coral to plum", "warm grey to soft gold"],
            representational: false),
    ]

    /// 依序輪替使用模板（舊行為；舊的每日進度檔續作時用）。
    static func rotated(count: Int, startingAt offset: Int = 0) -> [PromptTemplate] {
        guard !shared.isEmpty, count > 0 else { return [] }
        return (0..<count).map { shared[(offset + $0) % shared.count] }
    }
}

/// 使用者選的每日生成方式：哪些風格、要不要用自己的想法當主題。
struct DailyRecipe: Equatable, Sendable {
    static let stylesKey = "daily.styles"
    static let ideaKey = "daily.idea"
    static let ideaLimit = 200
    /// 手動「產生桌布」另存一組，不影響每日排程。
    static let manualPrefix = "manual"

    /// 選了哪些風格（範本 id）；空＝全部。
    var styles: [String] = []
    /// 自己的想法：有寫就當每張的主題，用選的風格畫出來。
    var idea = ""

    static func load(_ defaults: UserDefaults = .standard, prefix: String = "daily") -> Self {
        let known = Set(PromptTemplate.shared.map(\.id))
        let styles = (defaults.stringArray(forKey: prefix + ".styles") ?? []).filter(known.contains)
        return Self(styles: styles, idea: defaults.string(forKey: prefix + ".idea") ?? "")
    }
    func save(_ defaults: UserDefaults = .standard, prefix: String = "daily") {
        defaults.set(styles, forKey: prefix + ".styles")
        defaults.set(String(idea.prefix(Self.ideaLimit)), forKey: prefix + ".idea")
    }

    /// 分類（與圖庫側欄相同順序）；一個分類可能對應多個風格。
    static var categories: [String] {
        var seen = Set<String>()
        return PromptTemplate.shared.map(\.category).filter { seen.insert($0).inserted }
    }
    /// 選了哪些分類（空＝全部）。
    var categories: [String] {
        Self.categories.filter { category in
            PromptTemplate.shared.contains { $0.category == category && styles.contains($0.id) }
        }
    }
    mutating func setCategory(_ category: String, on: Bool) {
        let ids = PromptTemplate.shared.filter { $0.category == category }.map(\.id)
        var next = styles.filter { !ids.contains($0) }
        if on { next += ids }
        styles = PromptTemplate.shared.map(\.id).filter(next.contains)
    }

    var templates: [PromptTemplate] {
        let picked = PromptTemplate.shared.filter { styles.contains($0.id) }
        return picked.isEmpty ? PromptTemplate.shared : picked
    }
    var trimmedIdea: String {
        String(idea.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.ideaLimit))
    }
}

/// 一張要生成的圖：用哪個風格、檔名前綴、送出的提示詞。
struct PlannedPrompt: Codable, Equatable, Sendable {
    var templateID: String
    var slug: String
    var prompt: String

    var template: PromptTemplate? { PromptTemplate.shared.first { $0.id == templateID } }
    var title: String { template?.title ?? templateID }
}

enum DailyPlan {
    /// 同一天、同一組設定結果固定（續作時才對得上）；不同天主題、配色、光線、構圖都換。
    static func make(day: String, count: Int, recipe: DailyRecipe, salt: String = "") -> [PlannedPrompt] {
        guard count > 0 else { return [] }
        let templates = recipe.templates
        let idea = recipe.trimmedIdea
        // 主題、配色、光線、構圖都依「第幾天」輪替：同一風格要把主題全部用過一輪才會重複，
        // 隔天一定換；手動生成另加 salt，與當天的每日批次錯開。
        let dayNumber = dayIndex(day) + (salt.isEmpty ? 0 : Int(DynamicAutoPlanner.stableHash(salt) % 997))
        let offset = dayNumber % templates.count
        var used: [String: Int] = [:]
        return (0..<count).map { index in
            let template = templates[(offset + index) % templates.count]
            let round = used[template.id, default: 0]
            used[template.id] = round + 1
            let base = Int(DynamicAutoPlanner.stableHash(template.id) % 1000)
            func pick<T>(_ list: [T], stride: Int) -> T { list[(base + dayNumber * stride + round) % list.count] }
            let subject = idea.isEmpty ? pick(template.subjects, stride: 1) : idea
            // 自己的想法：主題固定，靠配色、光線、構圖做出差異（同一天多張也各不同）。
            let palette = pick(template.palettes, stride: 1)
            let light = pick(PromptTemplate.lights, stride: 5)
            let composition = pick(PromptTemplate.compositions, stride: 1 + (idea.isEmpty ? 0 : 1))
            let slug = round == 0 ? template.id : "\(template.id)-\(round + 1)"
            return PlannedPrompt(templateID: template.id, slug: slug,
                                 prompt: template.compose(subject: subject, palette: palette, light: light, composition: composition))
        }
    }

    /// "yyyy-MM-dd" → 從 2000-01-01 起第幾天；看不懂就用雜湊。
    static func dayIndex(_ day: String) -> Int {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let days = calendar.dateComponents([.day], from: calendar.date(from: DateComponents(year: 2000, month: 1, day: 1))!, to: date).day,
              days >= 0 else { return Int(DynamicAutoPlanner.stableHash(day) % 100_000) }
        return days
    }

    /// 舊版進度檔沒有存計畫：檔名照舊輪替，提示詞用新的組法。
    static func legacy(day: String, count: Int) -> [PlannedPrompt] {
        let templates = PromptTemplate.rotated(count: count)
        let fresh = make(day: day, count: count, recipe: DailyRecipe(styles: [], idea: ""))
        return templates.enumerated().map { index, template in
            let match = fresh.first { $0.templateID == template.id }?.prompt ?? template.prompt
            return PlannedPrompt(templateID: template.id, slug: template.id, prompt: index < fresh.count ? match : template.prompt)
        }
    }
}
