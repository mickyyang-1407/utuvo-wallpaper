import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import UTUVOWallpaper

/// 假 provider：依腳本回傳成功（PNG）或錯誤；記錄每次呼叫。絕不連網。
final class ScriptedProvider: ImageProvider, @unchecked Sendable {
    enum Step { case ok, fail(GenerationError) }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var prompts: [String] = []
    private(set) var relightPrompts: [String] = []
    var onCall: ((Int) -> Void)?
    let size: CGSize

    init(_ steps: [Step], size: CGSize = CGSize(width: 216, height: 384)) {
        self.steps = steps
        self.size = size
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return prompts.count + relightPrompts.count }

    private func next() throws -> Data {
        lock.lock()
        let step = steps.isEmpty ? Step.ok : steps.removeFirst()
        lock.unlock()
        switch step {
        case .ok: return TestImage.png(size: size)
        case .fail(let e): throw e
        }
    }

    private func record(prompt: String, relight: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        if relight { relightPrompts.append(prompt) } else { prompts.append(prompt) }
        return prompts.count
    }

    func generateImage(prompt: String) async throws -> Data {
        let n = record(prompt: prompt, relight: false)
        onCall?(n)
        return try next()
    }

    func relight(reference: Data, prompt: String) async throws -> Data {
        _ = record(prompt: prompt, relight: true)
        return try next()
    }
}

enum TestImage {
    static func png(size: CGSize) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.65, 0.39, 0.27, 1])!)
        ctx.fill(CGRect(origin: .zero, size: size))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}

/// 每個測試一個暫存根目錄，tearDown 刪除。
func makeTempPaths() -> AppPaths {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("utuvo-wallpaper-tests-" + UUID().uuidString)
    return AppPaths(root: url)
}

/// URLProtocol 樁：攔下所有請求、不連網；回傳指定狀態與 body，並記錄請求。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var captured: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured.append(request)
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                bodyData.append(buffer, count: n)
            }
            stream.close()
        }
        Self.capturedBodies.append(bodyData)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json", "X-Request-Id": "req_secret_header"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() { status = 200; body = Data(); captured = []; capturedBodies = [] }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }
}
