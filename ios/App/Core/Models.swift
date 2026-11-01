import Foundation

/// 錯誤種類與 Mac 版同名（共用的 `DailyBatch.isRetryable` 依賴這些 case）。
/// 訊息只帶狀態碼，絕不包含 key、raw response 或 headers。
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
    case cooldown

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return L("提示詞是空的，無法送出請求。")
        case .missingCredential:
            return L("找不到 API key。請到「設定」把自己的 OpenAI API key 存進 iPhone 鑰匙圈。")
        case .invalidResponse:
            return L("API 回應格式無法解析（沒有可用的圖片資料）。")
        case .httpStatus(let code):
            switch code {
            case 401, 403:
                return L("API 授權失敗（HTTP \(code)）：憑證無效或沒有這個模型的權限。")
            case 429:
                return L("API 額度不足或被限流（HTTP 429）。稍後會自動再試，最多 3 次。")
            case 400:
                return L("API 拒絕請求（HTTP 400）：參數或模型名稱不被接受。")
            case 500...599:
                return L("API 伺服器錯誤（HTTP \(code)）。稍後會自動再試，最多 3 次。")
            default:
                return L("API 請求失敗（HTTP \(code)）。")
            }
        case .timeout:
            return L("API 請求逾時。")
        case .transport:
            return L("API 連線失敗。")
        case .decoding:
            return L("回應的圖片資料解碼失敗。")
        case .writeFailed:
            return L("寫入檔案失敗。")
        case .cancelled:
            return L("已取消。")
        case .cooldown:
            return L("今天的批次正在冷卻或已達重試上限，稍後再試。")
        }
    }
}

/// 一次生成下來的結果（欄位與 Mac 版相同，存進共用的 `DailyBatch` 進度檔）。
struct GeneratedWallpaper: Sendable, Codable, Equatable {
    let title: String
    let nativeURL: String
    let nativePixelSize: String
    let wallpaperURL: String
    let wallpaperPixelSize: String
    let origin: String
}

/// 產生檔名用的隨機識別碼。
enum RandomID {
    static func make() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}
