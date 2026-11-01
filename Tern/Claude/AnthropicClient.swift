import Foundation

/// A minimal streaming client for the Anthropic Messages API. It blocks the calling (shell) thread
/// until the response is complete, streaming assistant text to `onText` as it arrives and assembling
/// the assistant's content blocks (text and tool_use) for the next turn.
final class AnthropicClient: NSObject, URLSessionDataDelegate {
    struct ToolUse {
        let id: String
        let name: String
        let input: [String: Any]
    }

    struct Reply {
        /// The assistant's content blocks, in order, ready to append to the conversation as the
        /// `assistant` message (text blocks and tool_use blocks).
        var content: [[String: Any]] = []
        var toolUses: [ToolUse] = []
        var stopReason: String?
        /// Set when the request failed (HTTP error, network error, or a stream error event).
        var error: String?
    }

    private let apiKey: String
    private let baseURL: String

    init(apiKey: String, baseURL: String) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    // Per-request streaming state.
    private var blocks: [Int: (type: String, text: String, toolID: String, toolName: String, json: String)] = [:]
    private var reply = Reply()
    private var onText: ((String) -> Void)?
    private var httpStatus = 0
    private var errorBody = Data()
    private var lineBuffer = Data()
    private let done = DispatchSemaphore(value: 0)
    private var interrupted: () -> Bool = { false }

    /// Sends one request and returns when the stream finishes. `onText` is called on a background
    /// thread with each text delta. `isInterrupted` is polled so Ctrl-C can abort a long response.
    func send(body: [String: Any], onText: @escaping (String) -> Void, isInterrupted: @escaping () -> Bool = { false }) -> Reply {
        self.onText = onText
        self.interrupted = isInterrupted
        blocks = [:]
        reply = Reply()
        httpStatus = 0
        errorBody = Data()
        lineBuffer = Data()

        guard let url = URL(string: baseURL + "/v1/messages") else {
            reply.error = "Invalid base URL: \(baseURL)"
            return reply
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            reply.error = "Could not encode the request."
            return reply
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = payload

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()

        // Poll so Ctrl-C can cancel; otherwise wait for the stream to finish.
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if interrupted() {
                task.cancel()
                reply.error = reply.error ?? "Interrupted."
                break
            }
        }
        session.finishTasksAndInvalidate()
        return reply
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard httpStatus == 200 else {
            errorBody.append(data)
            return
        }
        lineBuffer.append(data)
        let newline = UInt8(0x0A)
        while let index = lineBuffer.firstIndex(of: newline) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<index)
            lineBuffer.removeSubrange(lineBuffer.startIndex...index)
            handleLine(String(decoding: lineData, as: UTF8.self))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if httpStatus != 200 {
            reply.error = httpErrorMessage()
        } else if let error, (error as NSError).code != NSURLErrorCancelled {
            reply.error = error.localizedDescription
        }
        reply.content = assembleContent()
        done.signal()
    }

    // MARK: SSE parsing

    private func handleLine(_ rawLine: String) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else { return }
        handleEvent(type: type, event: event)
    }

    private func handleEvent(type: String, event: [String: Any]) {
        switch type {
        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return }
            blocks[index] = (type: blockType, text: "",
                             toolID: block["id"] as? String ?? "",
                             toolName: block["name"] as? String ?? "", json: "")
        case "content_block_delta":
            guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { return }
            if let text = delta["text"] as? String {
                blocks[index]?.text += text
                onText?(text)
            } else if let partial = delta["partial_json"] as? String {
                blocks[index]?.json += partial
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                reply.stopReason = stop
            }
        case "error":
            if let error = event["error"] as? [String: Any], let message = error["message"] as? String {
                reply.error = message
            }
        default:
            break
        }
    }

    private func assembleContent() -> [[String: Any]] {
        var content: [[String: Any]] = []
        for index in blocks.keys.sorted() {
            guard let block = blocks[index] else { continue }
            if block.type == "text" {
                if !block.text.isEmpty {
                    content.append(["type": "text", "text": block.text])
                }
            } else if block.type == "tool_use" {
                let input = (try? JSONSerialization.jsonObject(with: Data(block.json.utf8))) as? [String: Any] ?? [:]
                content.append(["type": "tool_use", "id": block.toolID, "name": block.toolName, "input": input])
                reply.toolUses.append(ToolUse(id: block.toolID, name: block.toolName, input: input))
            }
        }
        return content
    }

    private func httpErrorMessage() -> String {
        if let object = (try? JSONSerialization.jsonObject(with: errorBody)) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return "API error (\(httpStatus)): \(message)"
        }
        let text = String(decoding: errorBody, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return "API error (\(httpStatus)): \(text)" }
        return "API request failed with status \(httpStatus)."
    }
}
