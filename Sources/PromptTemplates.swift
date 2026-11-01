import Foundation

/// 一組原創風格提示詞模板。
///
/// 設計原則：
/// - 只描述「風格與主題」，不模仿任何在世畫家或特定藝術家的風格。
/// - 每張圖 16:9、純圖像、無文字、無浮水印。
struct PromptTemplate: Identifiable, Hashable, Sendable {
    let id: String
    /// 中文介面顯示的名稱
    let title: String
    /// 分類
    let category: String
    /// 送給模型的提示詞（英文，模型效果較穩）
    let prompt: String

    static let shared: [PromptTemplate] = [
        PromptTemplate(
            id: "nature-dawn",
            title: "自然 · 破曉山稜",
            category: "自然",
            prompt: """
            A serene alpine mountain range at first light, low mist drifting between layered \
            ridgelines, cool blue shadows warming to pale gold on the peaks, delicate atmospheric \
            depth, natural photographic realism, ultra detailed, wide 16:9 desktop wallpaper \
            composition, no text, no watermark, no people.
            """
        ),
        PromptTemplate(
            id: "minimal-paper",
            title: "極簡 · 紙上遠山",
            category: "極簡",
            prompt: """
            Minimalist paper-craft landscape, soft off-white paper texture with a single band of \
            muted teal and pale ochre, one distant mountain silhouette, vast negative space, \
            subtle grain, flat graphic design with restrained color palette, elegant and calm, \
            16:9 desktop wallpaper, no text, no watermark.
            """
        ),
        PromptTemplate(
            id: "abstract-flow",
            title: "抽象 · 流動光帶",
            category: "抽象",
            prompt: """
            Abstract flowing ribbons of light, smooth gradient mesh in deep indigo, violet and \
            warm amber, silky curved bands with soft blur transitions, luminous depth, no hard \
            edges, premium generative art wallpaper, 16:9, no text, no watermark, no logos.
            """
        ),
        PromptTemplate(
            id: "illustration-dusk",
            title: "插畫 · 黃昏街角",
            category: "插畫",
            prompt: """
            Editorial illustration of a quiet city corner at dusk, warm shop windows, bicycles \
            against a brick wall, long violet shadows, flat vector shapes with subtle grain \
            texture, limited palette of coral, indigo and cream, charming and calm, \
            16:9 desktop wallpaper, no text, no watermark.
            """
        ),
        PromptTemplate(
            id: "cosmic-nebula",
            title: "宇宙 · 星雲深處",
            category: "宇宙",
            prompt: """
            Deep space nebula, dust lanes and faint starlight, teal and magenta clouds against \
            near-black sky, subtle spiral structure, astrophotography realism with artistic color \
            grading, very high detail, 16:9 desktop wallpaper, no text, no watermark, no planets \
            in the center.
            """
        ),
        PromptTemplate(
            id: "botanical-macro",
            title: "自然 · 葉脈微距",
            category: "自然",
            prompt: """
            Macro photograph of a single backlit leaf, intricate vein structure glowing emerald \
            against a soft dark bokeh background, dew droplets catching light, high detail, \
            natural color science, vertical texture yet wide 16:9 framing, \
            no text, no watermark.
            """
        ),
        PromptTemplate(
            id: "watercolor-meadow",
            title: "水彩 · 田園午後",
            category: "水彩",
            prompt: """
            Original watercolor landscape of rolling meadows and a narrow winding path,
            soft afternoon light, transparent washes of sage green, honey and dusty rose,
            visible cold-pressed paper texture, loose edges, spacious composition,
            quiet and inviting, wide 16:9 desktop wallpaper, no text, no watermark.
            """
        ),
        PromptTemplate(
            id: "architecture-arcade",
            title: "建築 · 沙色拱廊",
            category: "建築",
            prompt: """
            Architectural photograph of a sunlit sandstone arcade, repeated rounded arches,
            warm limestone, terracotta floor, long geometric shadows and a small olive tree,
            precise material detail, restrained composition, no people,
            wide 16:9 desktop wallpaper, no text, no watermark.
            """
        ),
        PromptTemplate(
            id: "animation-coast",
            title: "動畫 · 海邊車站",
            category: "動畫",
            prompt: """
            Original hand-drawn animation background of a tiny seaside railway station,
            an empty platform overlooking a turquoise bay, distant hills and summer clouds,
            delicate painted textures, expressive clean linework, muted cream and coral,
            gentle nostalgic atmosphere, wide 16:9 desktop wallpaper,
            no characters, no text, no watermark, no logos.
            """
        ),
        PromptTemplate(
            id: "gradient-tide",
            title: "抽象 · 潮汐漸層",
            category: "抽象",
            prompt: """
            Soft gradient tide, layered horizontal color fields from deep ocean blue through \
            teal to pale sand, extremely smooth transitions, subtle film grain, minimal abstract \
            wallpaper with calm horizontal rhythm, 16:9, no text, no watermark.
            """
        )
    ]

    /// 依序輪替使用模板。
    static func rotated(count: Int, startingAt offset: Int = 0) -> [PromptTemplate] {
        guard !shared.isEmpty, count > 0 else { return [] }
        return (0..<count).map { shared[(offset + $0) % shared.count] }
    }
}
