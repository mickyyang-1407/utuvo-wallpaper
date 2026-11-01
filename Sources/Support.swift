import Foundation
import CoreGraphics
import OSLog

// MARK: - 日誌
// 規則：日誌只能寫「已分類的結果」，不得帶 request / headers / key / raw body。
enum LabLog {
    static let subsystem = "com.utuvo.wallpaper-lab"
    static let general = Logger(subsystem: subsystem, category: "general")
    static let generate = Logger(subsystem: subsystem, category: "generate")
    static let desktop = Logger(subsystem: subsystem, category: "desktop")
}

// MARK: - 影像來源標記

/// 標記這張圖是 AI 原生輸出，還是後來重採樣／放大的產物。
enum ImageOrigin: String, Sendable, Hashable {
    /// AI 直接輸出（3840×2160 原生）
    case native
    /// 由原生 PNG 以 CoreGraphics 高品質重採樣到 6K（6144×3456）
    case resampled
    /// 以 AI 超解析模型放大（與重採樣不同，必須分開標示）
    case aiUpscaled
    /// 來源不明（例如使用者自己放的圖）
    case unknown

    var label: String {
        switch self {
        case .native: return L("原生")
        case .resampled: return L("重採樣")
        case .aiUpscaled: return L("AI 放大")
        case .unknown: return L("未知")
        }
    }
}

// MARK: - 桌布模型

struct Wallpaper: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let origin: ImageOrigin

    var pixelText: String { "\(pixelWidth) × \(pixelHeight)" }

    var sizeText: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var name: String { url.lastPathComponent }
    var category: String { WallpaperLibrary.category(forFileName: name) }
}

// MARK: - 生成錯誤

enum GenerationError: LocalizedError, Sendable, Equatable {
    case emptyPrompt
    case missingCredential
    case invalidResponse
    case httpStatus(Int)
    case timeout
    case transport
    case decoding
    case writeFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return L("提示詞是空的，無法送出請求。")
        case .missingCredential:
            return L("找不到 API key。請開啟設定，將自己的 OpenAI API key 儲存到 Mac 鑰匙圈；命令列也可使用 OPENAI_API_KEY。")
        case .invalidResponse:
            return L("API 回應格式無法解析（沒有可用的圖片資料）。")
        case .httpStatus(let code):
            switch code {
            case 401, 403:
                return L("API 授權失敗（HTTP \(code)）：憑證無效或沒有這個模型的權限。")
            case 429:
                return L("API 額度不足或被限流（HTTP 429）。依規定不自動重試，避免重複計費。")
            case 400:
                return L("API 拒絕請求（HTTP 400）：參數或模型名稱不被接受。")
            case 500...599:
                return L("API 伺服器錯誤（HTTP \(code)）。依規定不自動重試。")
            default:
                return L("API 請求失敗（HTTP \(code)）。")
            }
        case .timeout:
            return L("API 請求逾時。依規定不自動重試，避免重複計費。")
        case .transport:
            return L("API 連線失敗。依規定不自動重試，避免重複計費。")
        case .decoding:
            return L("回應的圖片資料解碼失敗。")
        case .writeFailed:
            return L("寫入檔案失敗。")
        case .cancelled:
            return L("已取消。")
        }
    }
}

// MARK: - 桌面相關錯誤

enum DesktopError: LocalizedError, Sendable, Equatable {
    case noDisplays
    case originalUnknown(String)
    case applyFailed(String)
    case readbackUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            return L("找不到任何螢幕。")
        case .originalUnknown(let name):
            return L("無法取得「\(name)」目前的桌布路徑，為安全起見不修改這顆螢幕。")
        case .applyFailed(let name):
            return L("設定「\(name)」桌布失敗。")
        case .readbackUnavailable(let reason):
            return L("無法讀回桌面：\(reason)")
        }
    }
}

// MARK: - 小工具

enum ByteSize {
    static func text(for bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// 產生檔名用的隨機識別碼（不覆蓋既有檔案）。
enum RandomID {
    static func make() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789".utf8)
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(8)
        for _ in 0..<8 {
            bytes.append(alphabet[Int(rng.next(upperBound: UInt64(alphabet.count)))])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
