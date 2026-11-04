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
    /// 本機直接畫（"solid" 純色、"gradient" 漸層），不送 AI；palettes 放色碼規格。
    var local: String? = nil

    /// 預設組合（第一個主題、第一組配色）。
    var prompt: String { compose(subject: subjects[0], palette: palettes[0], light: nil, composition: nil) }

    func compose(subject: String, palette: String, light: String?, composition: String?, detail: String? = nil,
                 artStyle: String? = nil) -> String {
        if let local { return LocalArt.prefix + local + ":" + palette }
        let lead = artStyle.map { "Art style: \($0), rich detail, calm mood" } ?? style
        var parts = [lead, "Subject: \(subject)", "Palette: \(palette)"]
        if let light, representational { parts.append(light) }
        if let composition { parts.append(composition) }
        if let detail { parts.append(detail) }
        parts.append("wide 16:9 desktop wallpaper, no text, no watermark, no logos")
        return parts.joined(separator: ". ") + "."
    }

    static let lights = [
        "soft early morning light", "clear midday light", "warm late afternoon light",
        "golden hour backlight", "overcast diffused light", "blue hour after sunset",
        "misty morning haze", "dramatic light breaking through clouds", "soft light after rain",
        "dappled light through leaves", "moonlight with a few warm lamps", "bright crisp winter light",
    ]
    static let compositions = [
        "wide open composition with generous negative space", "low horizon with a large sky",
        "subject placed off-center on the right third", "subject placed off-center on the left third",
        "layered foreground, middle ground and distance", "calm symmetrical composition",
        "seen from a low angle looking up", "seen from above, looking down",
        "close-up with a softly blurred background", "framed through a window or archway",
        "a small subject in a vast space", "a gentle diagonal leading the eye through the frame",
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
        // 競品常見、我們原本沒有的分類（2026-11-02）。純色、漸層在本機畫，不花額度。
        PromptTemplate(
            id: "solid-color", title: "純色 · 純色", category: "純色", style: "", subjects: ["solid"],
            palettes: ["#1C2B4A", "#2F4F3E", "#B5543A", "#D8C3A5", "#8FA99A", "#9C7A97", "#2B2B2E", "#EFE9DD",
                       "#1F6F8B", "#D9A441", "#5B6C8F", "#C46A7A", "#3E5641", "#E7D2C3", "#0E1116", "#7A8B99",
                       "#A63A50", "#4A6FA5", "#C9B79C", "#264653", "#E76F51", "#6D597A", "#F4A261", "#84A59D"],
            representational: false, local: "solid"),
        PromptTemplate(
            id: "gradient-soft", title: "漸層 · 漸層", category: "漸層", style: "", subjects: ["gradient"],
            palettes: ["#0F2027,#203A43,#2C5364|120", "#FF9A8B,#FF6A88,#FF99AC|135", "#355C7D,#6C5B7B,#C06C84|160",
                       "#134E5E,#71B280|110", "#F7971E,#FFD200|90", "#1D2B64,#F8CDDA|150", "#4568DC,#B06AB3|135",
                       "#0B486B,#F56217|125", "#43C6AC,#191654|140", "#FBD3E9,#BB377D|100", "#232526,#414345|90",
                       "#FFE29F,#FFA99F,#FF719A|130", "#2E3192,#1BFFFF|145", "#C9D6FF,#E2E2E2|90", "#3A1C71,#D76D77,#FFAF7B|135",
                       "#16222A,#3A6073|115"],
            representational: false, local: "gradient"),
        PromptTemplate(
            id: "dark-oled", title: "深色 · 深色", category: "深色",
            style: "Dark wallpaper for OLED screens, mostly pure black background, a single softly lit subject, high contrast, quiet and minimal",
            subjects: ["a thin crescent moon", "a single glowing neon line curving through darkness", "a faint spiral galaxy",
                       "the edge of a black sand dune catching light", "a lone paper lantern", "a rim-lit flower",
                       "the crest of a dark ocean wave", "a mountain ridge silhouette under faint stars"],
            palettes: ["pure black with cool blue light", "black with warm amber glow", "black with violet rim light", "black with silver highlights"]),
        PromptTemplate(
            id: "geometric", title: "幾何 · 幾何", category: "幾何",
            style: "Clean geometric pattern design, precise vector shapes, balanced repetition, subtle depth and soft shadows",
            subjects: ["interlocking hexagons", "concentric circles", "isometric cubes", "a Bauhaus composition of circles and squares",
                       "a grid of flowing lines", "a triangular mosaic", "an art deco fan pattern", "overlapping arcs"],
            palettes: ["navy, mustard and cream", "terracotta, sage and sand", "black, white and one red accent", "pastel mint, peach and lilac",
                       "deep teal and gold"],
            representational: false),
        PromptTemplate(
            id: "city", title: "城市 · 城市", category: "城市",
            style: "City photography, cinematic realism, natural detail, no people in focus, no readable signs",
            subjects: ["a Taipei street at night after rain", "a narrow Tokyo alley with lanterns", "New York rooftops with water towers",
                       "the Hong Kong harbour skyline", "a Paris boulevard in autumn", "a Lisbon tram on a steep hill",
                       "a Seoul street with soft neon", "a quiet Singapore riverside"],
            palettes: ["teal and orange city lights", "soft pastel morning tones", "deep blue hour with warm windows", "muted film colors"]),
        PromptTemplate(
            id: "animals", title: "動物 · 動物", category: "動物",
            style: "Wildlife photograph, natural habitat, sharp detail on the eyes, shallow depth of field, calm mood",
            subjects: ["a red fox in fresh snow", "a cat sleeping by a sunny window", "a humpback whale breaching", "a hummingbird near a flower",
                       "a deer in a misty forest", "an owl at dusk", "a sea turtle in clear water", "koi fish in a quiet pond"],
            palettes: ["natural earthy colors", "soft winter whites and blues", "warm golden tones", "lush greens"]),
        PromptTemplate(
            id: "render-3d", title: "3D · 3D 立體", category: "3D",
            style: "Soft 3D render, smooth clay-like materials, gentle studio lighting and soft shadows, playful minimal scene",
            subjects: ["floating pastel spheres", "a tiny island diorama", "stacked geometric blocks", "glass marbles on a soft surface",
                       "abstract arches and steps", "puffy cloud shapes", "low-poly mountains", "a toy-like city block"],
            palettes: ["pastel pink and baby blue", "cream, sage and coral", "lilac and soft yellow", "monochrome warm white"],
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

    static func load(_ defaults: UserDefaults = AppDefaults.shared, prefix: String = "daily") -> Self {
        let known = Set(PromptTemplate.shared.map(\.id))
        let styles = (defaults.stringArray(forKey: prefix + ".styles") ?? []).filter(known.contains)
        return Self(styles: styles, idea: defaults.string(forKey: prefix + ".idea") ?? "")
    }
    func save(_ defaults: UserDefaults = AppDefaults.shared, prefix: String = "daily") {
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
    /// 選的分類全是本機畫的（純色／漸層）：不需要 API key。
    var isLocalOnly: Bool { templates.allSatisfy { $0.local != nil } }
    var trimmedIdea: String {
        String(idea.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.ideaLimit))
    }
}

/// 「AI 靈感」：依分類挑一個主題點子填進 Prompt 欄（本機挑選，不連網、不花額度）。
enum PromptInspiration {
    static let ideas: [String: [(zh: String, en: String)]] = [
        "自然": [("清晨霧氣中的竹林小徑", "a bamboo path in morning mist"), ("冰河湖上漂著藍色浮冰", "blue icebergs drifting on a glacier lake"),
                ("秋天山谷裡的紅葉與溪流", "red autumn leaves along a valley stream"), ("暴風雨前的金色麥田", "a golden wheat field before a storm"),
                ("沙漠裡的一棵孤樹與星空", "a lone desert tree under the stars"), ("苔蘚覆蓋的古老森林", "an ancient moss-covered forest"),
                ("海浪打在黑色礁岩上", "waves crashing on black volcanic rocks"),
                ("火山口湖旁的硫磺煙", "steam rising beside a volcanic crater lake"),
                ("太魯閣峽谷裡的大理石溪", "a marble river in Taroko Gorge"),
                ("合歡山上的雲海", "a sea of clouds over Hehuan Mountain"),
                ("冰島黑沙灘上的玄武岩柱", "basalt columns on an Icelandic black-sand beach"),
                ("北極光下的雪原", "a snowfield under the northern lights"),
                ("熱帶雨林裡的瀑布", "a waterfall deep in a rainforest"),
                ("薰衣草田旁的白樺樹", "birch trees beside a lavender field"),
                ("退潮後的潮間帶", "tide pools at low tide"),
                ("紅色岩石的拱門", "a red sandstone arch"),
                ("開滿油菜花的田野", "a field of yellow rapeseed flowers"),
                ("高山湖泊倒映雪峰", "a high mountain lake mirroring snowy peaks"),
                ("海邊懸崖上的燈塔草原", "a grassy sea cliff with a lighthouse"),
                ("秋天的銀杏大道", "an avenue of golden ginkgo trees"),
                ("蘆葦隨風搖曳的濕地", "a wetland of reeds swaying in the wind"),
                ("珊瑚礁上的熱帶魚群", "tropical fish over a coral reef")],
        "極簡": [("一顆紅色氣球飄在灰色天空", "a single red balloon in a grey sky"), ("白色沙丘上的一道影子", "one shadow across white sand dunes"),
                ("海平線上的一艘小船", "a tiny boat on a flat horizon"), ("霧中的一盞路燈", "one streetlight in fog"),
                ("雪地裡的一排腳印", "a line of footprints in snow"), ("牆上的一扇藍色窗戶", "a single blue window on a white wall"),
                ("一張椅子與長長的影子", "one chair with a long shadow"),
                ("一片落葉在水面上", "a single leaf on still water"),
                ("空曠海灘上的一把傘", "one umbrella on an empty beach"),
                ("白牆上的一道光", "a single beam of light on a white wall"),
                ("一棵樹站在雪地中央", "one tree in the middle of a snowfield"),
                ("一根羽毛慢慢飄落", "a feather slowly falling"),
                ("一條路消失在地平線", "a road vanishing at the horizon"),
                ("一盞紙燈籠在黑暗中", "a paper lantern in the dark"),
                ("一隻鳥停在電線上", "one bird on a power line"),
                ("沙漠中的一扇門", "a lone door standing in a desert"),
                ("一個圓形窗戶看出去的天空", "the sky through a round window"),
                ("水面上的一圈漣漪", "a single ripple on water"),
                ("一顆檸檬在藍色桌面上", "one lemon on a blue table"),
                ("一條細細的金線劃過", "a thin gold line across the frame"),
                ("霧中山的一道稜線", "one mountain ridge in fog")],
        "抽象": [("流動的絲綢光帶", "flowing ribbons of silk light"), ("融化的極光色彩", "melting aurora colors"),
                ("玻璃碎片折射的彩虹", "rainbow light through broken glass"), ("液態金屬的漣漪", "ripples of liquid metal"),
                ("霓虹色的煙霧漩渦", "a swirl of neon smoke"), ("柔和的色塊互相融合", "soft color fields blending together"),
                ("墨水滴進水裡散開", "ink spreading through water"),
                ("大理石紋路的流動", "flowing marble veins"),
                ("聲波變成的彩色山脈", "sound waves turned into colorful mountains"),
                ("油彩厚塗的筆觸", "thick impasto brushstrokes"),
                ("全像箔紙的光澤", "holographic foil shimmer"),
                ("光線穿過稜鏡", "light passing through a prism"),
                ("細胞般的有機形狀", "organic cell-like shapes"),
                ("水彩暈染的邊界", "watercolor bleeding at the edges"),
                ("速度感的光軌", "streaks of light in motion"),
                ("鐵粉被磁鐵吸起的紋路", "iron filings following a magnetic field"),
                ("像地形圖的等高線", "contour lines like a topographic map"),
                ("透明玻璃般的波浪", "waves like clear glass"),
                ("粉彩煙霧輕輕交融", "pastel smoke softly merging"),
                ("像星塵一樣的顆粒", "grains like stardust"),
                ("色彩鮮明的拼貼紙片", "a collage of bright paper scraps")],
        "插畫": [("雨夜的台北巷口小吃攤", "a Taipei alley food stall on a rainy night"), ("屋頂上曬衣服的午後", "an afternoon of laundry drying on rooftops"),
                ("山城裡的復古電車", "a vintage tram in a hillside town"), ("海邊的小書店", "a tiny bookstore by the sea"),
                ("夜市裡的燈籠", "lanterns over a night market"), ("貓咪睡在窗台的咖啡館", "a cafe with a cat asleep on the windowsill"),
                ("騎腳踏車經過稻田的少年", "a kid riding a bike past rice fields"),
                ("巷口的柑仔店", "a tiny old corner shop in an alley"),
                ("颱風天窗外的雨", "a typhoon day seen through a window"),
                ("廟口的老榕樹", "an old banyan tree by a temple"),
                ("海邊的冰店", "a shaved-ice stand by the sea"),
                ("山上的茶屋", "a teahouse in the mountains"),
                ("下雨天撐傘的狐狸", "a fox holding an umbrella in the rain"),
                ("堆滿植物的陽台", "a balcony overflowing with plants"),
                ("夜裡亮著燈的便利商店", "a convenience store glowing at night"),
                ("熱氣球飛過小鎮", "hot-air balloons over a small town"),
                ("圖書館裡睡著的貓", "a cat asleep in a library"),
                ("森林裡的郵筒", "a mailbox in the middle of a forest"),
                ("屋頂上看星星的兩個人", "two friends stargazing on a rooftop"),
                ("月台上等車的旅人", "a traveler waiting on a train platform"),
                ("市場裡的水果攤", "a fruit stall in a busy market")],
        "宇宙": [("土星環上的日出", "sunrise over the rings of Saturn"), ("兩個星系正在碰撞", "two galaxies colliding"),
                ("太空站窗外的地球", "Earth seen from a space station window"), ("紫色星雲裡誕生的恆星", "stars being born in a violet nebula"),
                ("月球表面的地球升起", "Earthrise over the lunar surface"), ("黑洞邊緣彎曲的光", "light bending around a black hole"),
                ("木星大紅斑近看", "a close view of Jupiter's Great Red Spot"),
                ("外星沙漠上的兩個太陽", "two suns over an alien desert"),
                ("小行星帶裡的太空船", "a spaceship in an asteroid belt"),
                ("地球的夜景城市燈光", "Earth's city lights at night from orbit"),
                ("彗星拖著長長的尾巴", "a comet with a long glowing tail"),
                ("銀河拱橋跨過山頂", "the Milky Way arching over a mountaintop"),
                ("冰之衛星的冰裂縫", "ice cracks on a frozen moon"),
                ("環形星雲的眼睛", "the eye of a ring nebula"),
                ("火星上的藍色夕陽", "a blue sunset on Mars"),
                ("漂浮的太空人與地球", "an astronaut floating above Earth"),
                ("脈衝星發出的光束", "light beams from a pulsar"),
                ("星系的螺旋手臂", "the spiral arms of a galaxy"),
                ("流星雨劃過夜空", "a meteor shower across the sky"),
                ("日全食的日冕", "the corona of a total solar eclipse"),
                ("宇宙中漂浮的水晶", "crystals drifting through space")],
        "水彩": [("威尼斯運河的早晨", "a morning on a Venice canal"), ("薰衣草田裡的石屋", "a stone cottage in lavender fields"),
                ("下雪的京都寺廟", "a Kyoto temple in snow"), ("港口裡的彩色漁船", "colorful fishing boats in a harbor"),
                ("夏日海邊的陽傘", "beach umbrellas on a summer shore"), ("櫻花樹下的小橋", "a small bridge under cherry blossoms"),
                ("九份老街的階梯", "the stairs of Jiufen old street"),
                ("鹿港的紅磚巷", "a red-brick lane in Lukang"),
                ("托斯卡尼的柏樹小路", "a cypress road in Tuscany"),
                ("雨中的倫敦電話亭", "a London phone box in the rain"),
                ("湖邊的白鷺鷥", "an egret by a lake"),
                ("花市裡的繡球花", "hydrangeas at a flower market"),
                ("海邊的木棧道", "a wooden boardwalk by the sea"),
                ("秋天的公園長椅", "a park bench in autumn"),
                ("山腳下的小村莊", "a small village at the foot of a mountain"),
                ("巴黎的花窗陽台", "a Paris balcony full of flowers"),
                ("荷花池與涼亭", "a lotus pond with a pavilion"),
                ("北歐的彩色木屋", "colorful Nordic wooden houses"),
                ("麵包店的櫥窗", "a bakery shop window"),
                ("雪後的森林小屋", "a forest cabin after snowfall"),
                ("划船經過的蘆葦河道", "a rowboat passing through reeds")],
        "建築": [("清水模美術館的長廊", "a long concrete museum corridor"), ("螺旋樓梯由上往下看", "a spiral staircase seen from above"),
                ("玻璃溫室裡的熱帶植物", "tropical plants inside a glass greenhouse"), ("地中海白牆藍門", "Mediterranean white walls and blue doors"),
                ("夜裡發光的摩天大樓", "a skyscraper glowing at night"), ("老廠房改成的藝廊", "an old factory turned into a gallery"),
                ("日式庭園裡的茶室", "a tea house in a Japanese garden"),
                ("台南老屋的紅磚與花窗", "red brick and patterned windows of an old Tainan house"),
                ("巴塞隆納的彩色馬賽克", "colorful Barcelona mosaics"),
                ("圖書館的挑高書牆", "a towering library wall of books"),
                ("沙漠中的土磚城", "a mud-brick city in the desert"),
                ("鋼骨玻璃車站大廳", "a steel-and-glass station hall"),
                ("歐洲大教堂的玫瑰窗", "the rose window of a cathedral"),
                ("山上的寺廟階梯", "temple steps climbing a mountain"),
                ("北歐木造教堂", "a Nordic wooden stave church"),
                ("懸在峭壁上的房子", "a house hanging on a cliff"),
                ("拱廊下的光影", "light and shadow under arcades"),
                ("彩色的貨櫃屋", "colorful shipping-container houses"),
                ("水上的浮動屋", "a floating house on water"),
                ("老戲院的霓虹招牌", "the neon sign of an old cinema"),
                ("城堡的石造塔樓", "the stone towers of a castle")],
        "深色": [("黑夜裡的一彎新月", "a thin crescent moon in the dark"), ("黑暗中一條霓虹光線", "one neon line in darkness"),
                ("只有窗邊一盞燈的夜", "a night lit only by one window lamp"), ("深夜海面上的月光", "moonlight on a midnight sea"),
                ("黑色背景上的一朵白花", "a single white flower on black"), ("星空下的山脊剪影", "a ridge silhouette under stars"),
                ("暗夜裡發光的水母", "glowing jellyfish in dark water"),
                ("黑暗森林裡的螢火蟲", "fireflies in a dark forest"),
                ("深夜無人的地鐵站", "an empty subway station late at night"),
                ("黑色山巒上的閃電", "lightning over black mountains"),
                ("燭光照亮的一本書", "a book lit by candlelight"),
                ("暗處的一朵發光蘑菇", "a glowing mushroom in the shadows"),
                ("夜裡的雨滴與霓虹倒影", "raindrops and neon reflections at night"),
                ("黑夜裡的高速公路光軌", "highway light trails at night"),
                ("深海裡的燈籠魚", "an anglerfish in the deep sea"),
                ("黑底上的金色線條", "gold lines on black"),
                ("月光下的貓剪影", "a cat silhouette in moonlight"),
                ("暗房裡的紅燈", "the red light of a darkroom"),
                ("夜晚的極光與湖", "aurora over a lake at night"),
                ("黑暗中的一根火柴", "a single match burning in darkness"),
                ("夜裡的天文台", "an observatory at night")],
        "幾何": [("包浩斯風格的圓與方", "Bauhaus circles and squares"), ("層層疊疊的六角形", "stacked hexagons"),
                ("等角視角的立方體", "isometric cubes"), ("裝飾藝術風的扇形", "art deco fans"),
                ("流動的彩色線條網格", "a grid of flowing colored lines"), ("三角形馬賽克", "a triangle mosaic"),
                ("曼陀羅般的對稱圖形", "a symmetrical mandala pattern"),
                ("瑞士海報風格的色塊", "Swiss poster style color blocks"),
                ("摺紙般的立體三角", "origami-like folded triangles"),
                ("棋盤格與圓弧", "a checkerboard with arcs"),
                ("無限延伸的走廊錯覺", "an endless corridor illusion"),
                ("同心圓的漣漪", "rippling concentric circles"),
                ("孟菲斯風格的形狀", "Memphis style shapes"),
                ("彩色玻璃的幾何窗", "a geometric stained-glass window"),
                ("堆疊的半圓", "stacked half circles"),
                ("像磁磚一樣的星形", "tile-like star patterns"),
                ("線條組成的球體", "a sphere made of lines"),
                ("階梯狀的色帶", "stepped bands of color"),
                ("立體的蜂巢結構", "a 3D honeycomb structure"),
                ("交錯的彩色緞帶", "interlocking colored ribbons"),
                ("極簡的日出幾何", "a minimal geometric sunrise")],
        "城市": [("雨後的台北巷口夜景", "a Taipei alley at night after rain"), ("東京下町的小巷", "a small Tokyo backstreet"),
                ("香港維多利亞港的夜景", "Victoria Harbour at night"), ("紐約屋頂上的水塔", "water towers on New York rooftops"),
                ("里斯本爬坡的電車", "a Lisbon tram climbing a hill"), ("巴黎秋天的林蔭大道", "a Paris boulevard in autumn"),
                ("台北101與信義區的天際線", "the Taipei 101 skyline"),
                ("西門町的人潮與招牌", "crowds and signs in Ximending"),
                ("高雄的港邊倉庫", "harbor warehouses in Kaohsiung"),
                ("首爾的屋塔房", "rooftop houses in Seoul"),
                ("新加坡的濱海灣", "Marina Bay in Singapore"),
                ("伊斯坦堡的清真寺天際線", "the mosque skyline of Istanbul"),
                ("舊金山的爬坡街道", "a steep street in San Francisco"),
                ("哥本哈根的彩色港口", "the colorful harbor of Copenhagen"),
                ("阿姆斯特丹的運河單車", "bicycles along an Amsterdam canal"),
                ("上海外灘的老建築", "old buildings on the Shanghai Bund"),
                ("曼谷的水上市場", "a floating market in Bangkok"),
                ("京都的花見小路", "Hanamikoji street in Kyoto"),
                ("倫敦的雙層巴士", "a London double-decker bus"),
                ("雪中的布拉格廣場", "a Prague square in snow"),
                ("雨中的霓虹商店街", "a neon shopping street in the rain")],
        "動物": [("雪地裡的紅狐狸", "a red fox in the snow"), ("窗邊打盹的貓", "a cat napping by the window"),
                ("躍出海面的鯨魚", "a whale leaping out of the sea"), ("霧中森林裡的鹿", "a deer in a misty forest"),
                ("黃昏的貓頭鷹", "an owl at dusk"), ("清澈海水裡的海龜", "a sea turtle in clear water"),
                ("樹上抱著寶寶的無尾熊", "a koala holding its baby in a tree"),
                ("草原上的長頸鹿", "giraffes on the savanna"),
                ("冰原上的北極熊", "a polar bear on the ice"),
                ("荷葉上的青蛙", "a frog on a lotus leaf"),
                ("花叢中的蜂鳥", "a hummingbird among flowers"),
                ("台灣藍鵲", "a Taiwan blue magpie"),
                ("石虎在草叢裡", "a leopard cat in the grass"),
                ("一群企鵝在雪地", "a group of penguins in the snow"),
                ("水邊的翠鳥", "a kingfisher by the water"),
                ("溪裡的錦鯉", "koi in a stream"),
                ("樹枝上的松鼠", "a squirrel on a branch"),
                ("夜裡的螢火蟲與青蛙", "fireflies and a frog at night"),
                ("雪豹在山崖", "a snow leopard on a cliff"),
                ("海裡的鬼蝠魟", "a manta ray in the sea"),
                ("草地上打滾的柴犬", "a shiba inu rolling in the grass")],
        "3D": [("漂浮的粉彩圓球", "floating pastel spheres"), ("小島模型", "a tiny island diorama"),
               ("堆疊的積木", "stacked toy blocks"), ("柔軟的雲朵造型", "soft puffy clouds"),
               ("玻璃彈珠", "glass marbles"), ("低多邊形的山", "low-poly mountains"),
                ("黏土做的小城市", "a tiny city made of clay"),
                ("透明果凍般的山", "mountains like clear jelly"),
                ("毛茸茸的抽象生物", "a fluffy abstract creature"),
                ("糖果色的迷宮", "a candy-colored maze"),
                ("浮在空中的小房間", "a little room floating in the air"),
                ("金屬光澤的液態滴", "droplets of shiny liquid metal"),
                ("等角視角的咖啡店", "an isometric coffee shop"),
                ("紙雕般的層層山", "layered paper-cut mountains"),
                ("玩具火車穿過山洞", "a toy train going through a tunnel"),
                ("太空裡的小行星房子", "a tiny house on an asteroid"),
                ("霧面陶瓷的幾何體", "matte ceramic geometric shapes"),
                ("發光的水晶洞穴", "a glowing crystal cave"),
                ("扭曲的彩色管子", "twisting colorful tubes"),
                ("盆栽裡的小森林", "a tiny forest in a flowerpot"),
                ("像氣球一樣的字母", "balloon-like letter shapes")],
        "動畫": [("夏天的鄉間公車站", "a countryside bus stop in summer"), ("海邊的小火車站", "a little train station by the sea"),
                ("放學後的教室與夕陽", "an empty classroom at sunset after school"), ("祭典夜晚的煙火", "festival fireworks at night"),
                ("雲端上的浮空島", "floating islands above the clouds"), ("雨後屋頂上的彩虹", "a rainbow over rooftops after rain"),
                ("夏日祭典的金魚攤", "a goldfish-scooping stall at a summer festival"),
                ("海邊的老旅館", "an old seaside inn"),
                ("沿著鐵道走的少女", "a girl walking along the railway tracks"),
                ("在草原上奔跑的狗", "a dog running across a meadow"),
                ("魔法森林裡的小木屋", "a little cabin in a magical forest"),
                ("天空之城般的浮空城堡", "a castle floating in the sky"),
                ("雨後的神社石階", "shrine stone steps after rain"),
                ("屋頂上的天文社", "a school astronomy club on the rooftop"),
                ("坡道上的腳踏車", "a bicycle on a steep slope"),
                ("漂浮在海上的燈籠", "lanterns floating on the sea"),
                ("山間的蒸汽火車", "a steam train in the mountains"),
                ("夏天的冰涼汽水", "a cold bottle of soda in summer"),
                ("巨大積雨雲下的田野", "fields under towering summer clouds"),
                ("小鎮的麵包店早晨", "a morning at a small-town bakery"),
                ("夜晚的流星與兩個背影", "two figures watching shooting stars at night")],
    ]

    /// 氣氛／構圖小細節：約一半的點子會隨機加上一個，同一個主題也能變出不同畫面。
    static let details: [(zh: String, en: String)] = [
        ("畫面很安靜", "very quiet and calm"),
        ("帶一點懷舊感", "with a touch of nostalgia"),
        ("顏色偏暖", "in warm colors"),
        ("顏色偏冷", "in cool colors"),
        ("像電影的一幕", "like a still from a film"),
        ("從低角度往上看", "seen from a low angle"),
        ("從高處往下看", "seen from above"),
        ("留很多天空", "with lots of open sky"),
        ("對稱構圖", "in a symmetrical composition"),
        ("主體放在一側，留白給桌面圖示", "with the subject to one side and empty space for icons"),
        ("有一點霧", "with a little mist"),
        ("柔和的逆光", "with soft backlight"),
        ("遠處有一隻飛鳥", "with a bird far in the distance"),
        ("地上有一灘倒影", "with a reflection in a puddle"),
        ("微風吹動的感覺", "with a feeling of a gentle breeze"),
        ("細節很豐富", "full of small details"),
        ("像童話故事", "like a fairy tale"),
        ("有一點超現實", "slightly surreal"),
        ("柔和的粉彩色調", "in soft pastel tones"),
        ("高對比的光影", "with strong light and shadow"),
        ("下著毛毛雨", "in a light drizzle"),
        ("剛下過雪", "just after snowfall"),
        ("夏天的午後", "on a summer afternoon"),
        ("秋天的早晨", "on an autumn morning"),
    ]

    /// 依選的分類挑一個（沒選＝全部），盡量不跟目前欄位內容一樣；約一半會加一個小細節。
    static func pick(categories: [String], current: String, chinese: Bool,
                     random: () -> Int = { Int.random(in: 0..<1_000_000) }) -> String {
        // 純色、漸層沒有主題可想：只選它們時改從全部分類挑。
        let withIdeas = categories.filter { ideas[$0] != nil }
        let keys = withIdeas.isEmpty ? DailyRecipe.categories : withIdeas
        let pool = keys.flatMap { ideas[$0] ?? [] }
        guard !pool.isEmpty else { return current }
        for _ in 0..<8 {
            let roll = random()
            let idea = pool[roll % pool.count]
            let slot = (roll / pool.count) % (details.count * 2)
            var text = chinese ? idea.zh : idea.en
            if slot < details.count { text += chinese ? "，" + details[slot].zh : ", " + details[slot].en }
            if text != current { return text }
        }
        return chinese ? pool[0].zh : pool[0].en
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
            // 純色、漸層是本機畫的，不吃自己的 Prompt。
            let subject = idea.isEmpty || template.local != nil ? pick(subjectPool(template), stride: 1) : idea
            // 自己的想法：主題固定，靠配色、光線、構圖、氣氛做出差異（同一天多張也各不同）。
            let palette = pick(template.palettes, stride: 1)
            let light = pick(PromptTemplate.lights, stride: 5)
            let composition = pick(PromptTemplate.compositions, stride: idea.isEmpty ? 1 : 7)
            // 約一半的圖再加一句 AI 靈感的氣氛／構圖細節。
            let roll = Int(DynamicAutoPlanner.stableHash("\(day)#\(salt)#\(index)") % 1_000_000)
            let slot = roll % (PromptInspiration.details.count * 2)
            let detail = slot < PromptInspiration.details.count ? PromptInspiration.details[slot].en : nil
            // 內容型分類（自然風景、建築、城市、動物）約一半換畫風，不要每張都是攝影；自己寫想法時照想法走。
            let styleRoll = Int(DynamicAutoPlanner.stableHash("style#\(day)#\(salt)#\(index)") % 1_000_000)
            let artStyle = idea.isEmpty && mixedStyleTemplates.contains(template.id) && styleRoll % 2 == 1
                ? DynamicAutoPlanner.styles[(styleRoll / 2) % DynamicAutoPlanner.styles.count].en : nil
            let slug = round == 0 ? template.id : "\(template.id)-\(round + 1)"
            return PlannedPrompt(templateID: template.id, slug: slug,
                                 prompt: template.compose(subject: subject, palette: palette, light: light,
                                                          composition: composition, detail: detail, artStyle: artStyle))
        }
    }

    /// 分類講的是「畫什麼」而不是「怎麼畫」的風格，可以換畫風。
    static let mixedStyleTemplates: Set<String> = ["nature-dawn", "architecture-arcade", "city", "animals"]

    /// 每個風格可畫的主題：風格自己的＋同分類的 AI 靈感（英文），去重後依序輪替。
    static func subjectPool(_ template: PromptTemplate) -> [String] {
        guard template.local == nil else { return template.subjects }
        var seen = Set<String>()
        return (template.subjects + (PromptInspiration.ideas[template.category]?.map(\.en) ?? []))
            .filter { seen.insert($0).inserted }
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
