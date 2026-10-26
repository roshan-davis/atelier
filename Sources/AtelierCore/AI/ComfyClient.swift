import Foundation

public struct AIError: LocalizedError, Sendable {
    let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A file ComfyUI wrote, as its history reports it.
public struct ComfyImageRef: Codable, Hashable, Sendable {
    public var filename: String
    public var subfolder: String
    public var type: String
}

/// Talks to a ComfyUI server over its HTTP API: upload inputs, queue a workflow, wait for it
/// to finish, download what it saved.
public struct ComfyClient: Sendable {
    public var baseURL: URL
    let session: URLSession
    let clientID = UUID().uuidString

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Checks the server answers; returns its ComfyUI version when it reports one.
    public func ping() async throws -> String {
        let (data, _) = try await get("system_stats")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let system = json?["system"] as? [String: Any]
        return system?["comfyui_version"] as? String ?? "connected"
    }

    /// The choices a node's input offers, such as the installed checkpoints for
    /// CheckpointLoaderSimple's ckpt_name.
    public func options(node: String, input: String) async throws -> [String] {
        let (data, _) = try await get("object_info/\(node)")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let info = json?[node] as? [String: Any]
        let inputs = info?["input"] as? [String: Any]
        let spec = (inputs?["required"] as? [String: Any])?[input] as? [Any]
        // Older servers list the choices directly; newer ones as ["COMBO", {"options": [...]}].
        if let list = spec?.first as? [String] { return list }
        if let config = spec?.dropFirst().first as? [String: Any], let list = config["options"] as? [String] { return list }
        return []
    }

    /// Uploads a PNG into ComfyUI's input folder and returns the name to reference it by.
    public func upload(png: Data, name: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("upload/image"))
        request.httpMethod = "POST"
        let boundary = "Atelier-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("overwrite", "true")
        field("type", "input")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(png)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, _) = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = json["name"] as? String else { throw AIError("ComfyUI did not accept the image upload.") }
        let subfolder = json["subfolder"] as? String ?? ""
        return subfolder.isEmpty ? stored : "\(subfolder)/\(stored)"
    }

    /// Queues an API-format workflow and returns its prompt id.
    public func queue(_ workflow: [String: Any]) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("prompt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": workflow, "client_id": clientID])
        let (data, _) = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["prompt_id"] as? String else { throw AIError("ComfyUI did not queue the workflow.") }
        return id
    }

    /// Polls the history until the prompt finishes and returns the images it saved.
    public func outputs(of promptID: String, timeout: TimeInterval = 900,
                        progress: @Sendable (TimeInterval) -> Void = { _ in }) async throws -> [ComfyImageRef] {
        let start = Date()
        while true {
            try Task.checkCancellation()
            let (data, _) = try await get("history/\(promptID)")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entry = json[promptID] as? [String: Any] {
                let status = entry["status"] as? [String: Any]
                if status?["status_str"] as? String == "error" {
                    throw AIError("ComfyUI stopped with an error: \(Self.errorText(status) ?? "see the ComfyUI console").")
                }
                let outputs = entry["outputs"] as? [String: Any] ?? [:]
                var images: [ComfyImageRef] = []
                for key in outputs.keys.sorted() {
                    guard let node = outputs[key] as? [String: Any],
                          let list = node["images"] as? [[String: Any]] else { continue }
                    for item in list {
                        guard let filename = item["filename"] as? String else { continue }
                        images.append(ComfyImageRef(filename: filename, subfolder: item["subfolder"] as? String ?? "",
                                                    type: item["type"] as? String ?? "output"))
                    }
                }
                if !images.isEmpty { return images.filter { $0.type == "output" }.ifEmpty(images) }
                if status?["completed"] as? Bool == true { throw AIError("The workflow finished without saving an image.") }
            }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > timeout { throw AIError("ComfyUI took longer than \(Int(timeout / 60)) minutes.") }
            progress(elapsed)
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    public func download(_ image: ComfyImageRef) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "filename", value: image.filename),
                                 URLQueryItem(name: "subfolder", value: image.subfolder),
                                 URLQueryItem(name: "type", value: image.type)]
        let (data, _) = try await send(URLRequest(url: components.url!))
        return data
    }

    /// Stops whatever the server is running (Cancel in Atelier).
    public func interrupt() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("interrupt"))
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
    }

    // MARK: HTTP

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        try await send(URLRequest(url: baseURL.appendingPathComponent(path)))
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 60
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AIError("Can't reach ComfyUI at \(baseURL.absoluteString). Start it, or change the address in Settings > AI. (\(error.localizedDescription))")
        }
        guard let http = response as? HTTPURLResponse else { throw AIError("ComfyUI sent an unexpected reply.") }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError("ComfyUI refused the request (\(http.statusCode)): \(Self.describe(data))")
        }
        return (data, http)
    }

    /// The useful part of a ComfyUI error body, such as a missing model or node.
    static func describe(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8) ?? "no details"
        }
        var parts: [String] = []
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            parts.append(message)
        }
        if let nodes = json["node_errors"] as? [String: Any] {
            for case let node as [String: Any] in nodes.values {
                for case let error as [String: Any] in node["errors"] as? [Any] ?? [] {
                    let details = error["details"] as? String ?? ""
                    parts.append([error["message"] as? String ?? "", details].filter { !$0.isEmpty }.joined(separator: ": "))
                }
            }
        }
        return parts.isEmpty ? "no details" : parts.joined(separator: "; ")
    }

    private static func errorText(_ status: [String: Any]?) -> String? {
        for case let message as [Any] in status?["messages"] as? [Any] ?? [] {
            if message.first as? String == "execution_error", let body = message.last as? [String: Any] {
                return body["exception_message"] as? String
            }
        }
        return nil
    }
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}
