import Foundation

protocol SceneImageProvider: ImageProvider {
    func relight(reference: Data, prompt: String) async throws -> Data
}

extension OpenAIImageProvider: SceneImageProvider {
    func relight(reference: Data, prompt: String) async throws -> Data {
        let boundary = "UTUVO-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (key, value) in [("model", Self.model), ("size", Self.size),
                             ("quality", Self.quality), ("output_format", "png"), ("n", "1"), ("prompt", prompt)] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"reference.png\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(reference)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            LabLog.generate.error("scene edit URL error code=\(error.code.rawValue, privacy: .public)")
            if error.code == .cancelled { throw GenerationError.cancelled }
            throw error.code == .timedOut ? GenerationError.timeout : GenerationError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw GenerationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GenerationError.httpStatus(http.statusCode) }
        return try Self.extractImage(from: data)
    }
}

struct GeneratedScene: Codable {
    var prompt: String
    var directory: URL
    static var pointer: URL { LabPaths.deliveryRoot.appendingPathComponent("dynamic/current.json") }
    static func load() -> Self? {
        guard let data = try? Data(contentsOf: pointer) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func publish() throws {
        try FileManager.default.createDirectory(at: Self.pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.pointer, options: .atomic)
    }
}

struct DynamicGenerator {
    let provider: any SceneImageProvider
    func generate(prompt: String, directory: URL,
                  progress: @Sendable (Int) -> Void) async throws -> GeneratedScene {
        let prompt = try OpenAIImageProvider.validatePrompt(prompt)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = GeneratedScene(prompt: prompt, directory: directory)
        let manifest = directory.appendingPathComponent("scene.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let old = try JSONDecoder().decode(GeneratedScene.self, from: Data(contentsOf: manifest))
            guard old.prompt == prompt else { throw GenerationError.invalidResponse }
        } else { try JSONEncoder().encode(scene).write(to: manifest, options: .atomic) }
        let baseURL = directory.appendingPathComponent("day.png")
        let base: Data
        if FileManager.default.fileExists(atPath: baseURL.path) { base = try Data(contentsOf: baseURL) }
        else {
            base = try await provider.generateImage(prompt: """
            Create one calm photographic desktop landscape: \(prompt).
            Clear daytime lighting, fixed tripod, wide 16:9 composition, no text or watermark.
            Strong stable silhouettes and detailed natural materials. This is the exact reference for a day/night set.
            """)
            try ImageResampler.writePNG(base, to: baseURL)
        }
        for (index, phase) in [DynamicPhase.day, .dawn, .dusk, .night].enumerated() {
            try Task.checkCancellation()
            let native = directory.appendingPathComponent(phase.rawValue + ".png")
            let png: Data
            if FileManager.default.fileExists(atPath: native.path) { png = try Data(contentsOf: native) }
            else {
                let lighting: String
                switch phase {
                case .day: lighting = "clear daytime"
                case .dawn: lighting = "early dawn, pale pink horizon, low golden light, cool mist"
                case .dusk: lighting = "sunset twilight, warm amber horizon and cool violet shadows"
                case .night: lighting = "deep night, dark blue sky with stars, subtle moonlight and warm cabin window lights"
                }
                png = try await provider.relight(reference: base, prompt: """
                Relight this exact reference photograph to \(lighting).
                Preserve the identical camera, framing, perspective, horizon, terrain, buildings,
                trees, shoreline and all object positions. Change only illumination, exposure,
                sky color and physically appropriate reflections. No new objects, text or watermark.
                Output the same wide 16:9 scene, fully aligned to the reference.
                """)
                try ImageResampler.writePNG(png, to: native)
            }
            let jpeg = try ImageResampler.resampleToJPEG6K(pngData: png)
            try ImageResampler.writeJPEG(jpeg, to: directory.appendingPathComponent(phase.rawValue + ".jpg"))
            progress(index + 1)
        }
        let heic = directory.appendingPathComponent("mountain-hours.heic")
        if FileManager.default.fileExists(atPath: heic.path) { _ = try DynamicScene.describe(heic) }
        else { try DynamicScene.export(to: heic, directory: directory) }
        return scene
    }
}
