//
//  LLMClient+OpenAICompatible.swift
//  LLMKit
//
//  Direct transport to an OpenAI-compatible /chat/completions endpoint. Reuses LLMCore's
//  `asOpenAIMessages` for the message payload and forwards tool JSON-Schemas verbatim, so any
//  OpenAI-compatible server (OpenAI, Ollama, LiteLLM, vLLM, OpenRouter, …) works. Streaming
//  deltas are accumulated into full-state ChatMessageContent chunks, which is what AgentExecutor
//  expects (it replaces toolCalls wholesale from the latest chunk).
//

import Foundation
import LLMCore
import OpenAI

extension LLMClient {

    // MARK: - Streaming

    func streamChatOpenAICompatible(
        system: String,
        messages: [ChatMessageContent],
        tools: [ToolSchema]?
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        guard let cfg = openAIConfig else {
            throw LLMOpenAICompatibleError.notConfigured
        }
        // Inline local images to base64 (no uploader in custom mode), then convert to OpenAI wire form.
        let prepared = try await prepareUploadFiles(for: messages)
        let request = try Self.buildRequest(system: system, messages: prepared, tools: tools, stream: true, cfg: cfg)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try Self.checkStatus(response, bytes: nil)

                    var content = ""
                    // tool-call deltas accumulate by index: (id, name, arguments)
                    var toolAccum: [Int: (id: String, name: String, args: String)] = [:]

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OAIStreamChunk.self, from: data),
                              let choice = chunk.choices.first else { continue }

                        if let c = choice.delta.content { content += c }
                        if let tcs = choice.delta.toolCalls {
                            for tc in tcs {
                                var e = toolAccum[tc.index] ?? (id: "", name: "", args: "")
                                if let id = tc.id { e.id = id }
                                if let f = tc.function {
                                    if let n = f.name { e.name += n }
                                    if let a = f.arguments { e.args += a }
                                }
                                toolAccum[tc.index] = e
                            }
                        }

                        let toolCalls = Self.buildToolCalls(toolAccum)
                        let msg = ChatMessageContent(
                            role: .assistant,
                            content: content.isEmpty ? nil : content,
                            toolCalls: toolCalls.isEmpty ? nil : toolCalls
                        )
                        continuation.yield(.message(msg))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Non-streaming

    func chatOpenAICompatible(
        system: String,
        messages: [ChatMessageContent],
        tools: [ToolSchema]?
    ) async throws -> APIResponse<ChatMessageContent> {
        guard let cfg = openAIConfig else {
            throw LLMOpenAICompatibleError.notConfigured
        }
        let prepared = try await prepareUploadFiles(for: messages)
        let request = try Self.buildRequest(system: system, messages: prepared, tools: tools, stream: false, cfg: cfg)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkStatus(response, bytes: data)

        let parsed = try JSONDecoder().decode(OAIChatResponse.self, from: data)
        let m = parsed.choices.first?.message
        let toolCalls = m?.toolCalls?.map {
            ToolCall(id: $0.id, name: $0.function.name, arguments: $0.function.arguments)
        }
        let msg = ChatMessageContent(
            role: .assistant,
            content: m?.content,
            toolCalls: (toolCalls?.isEmpty == false) ? toolCalls : nil
        )
        return APIResponse(data: msg, usage: nil, credits: nil)
    }

    // MARK: - Request building

    private static func buildRequest(
        system: String,
        messages: [ChatMessageContent],
        tools: [ToolSchema]?,
        stream: Bool,
        cfg: OpenAICompatibleConfig
    ) throws -> URLRequest {
        // Messages → OpenAI wire JSON (reuses LLMCore's battle-tested converter).
        let msgData = try JSONEncoder().encode(messages.asOpenAIMessages)
        var msgArray = (try JSONSerialization.jsonObject(with: msgData)) as? [[String: Any]] ?? []
        if !system.isEmpty {
            msgArray.insert(["role": "system", "content": system], at: 0)
        }

        var body: [String: Any] = [
            "model": cfg.model,
            "stream": stream,
            "messages": msgArray
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = try tools.map { t -> [String: Any] in
                let pObj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t.parameters))
                return [
                    "type": "function",
                    "function": [
                        "name": t.name,
                        "description": t.description,
                        "parameters": pObj
                    ]
                ]
            }
        }

        var req = URLRequest(url: Self.completionsURL(base: cfg.baseURL))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Append `chat/completions` to the configured base unless it's already a full completions URL.
    private static func completionsURL(base: URL) -> URL {
        if base.path.hasSuffix("chat/completions") { return base }
        return base.appendingPathComponent("chat/completions")
    }

    private static func buildToolCalls(_ accum: [Int: (id: String, name: String, args: String)]) -> [ToolCall] {
        accum.sorted { $0.key < $1.key }.compactMap { idx, e in
            guard !e.name.isEmpty else { return nil }
            return ToolCall(
                id: e.id.isEmpty ? "call_\(idx)" : e.id,
                name: e.name,
                arguments: e.args.isEmpty ? "{}" : e.args
            )
        }
    }

    private static func checkStatus(_ response: URLResponse, bytes data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode < 400 else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw LLMOpenAICompatibleError.http(status: http.statusCode, body: body)
        }
    }
}

// MARK: - Errors

public enum LLMOpenAICompatibleError: LocalizedError {
    case notConfigured
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The OpenAI-compatible provider is not configured."
        case let .http(status, body):
            return "AI request failed (HTTP \(status)). \(body)"
        }
    }
}

// MARK: - Wire decoders (minimal; only the fields we consume)

private struct OAIStreamChunk: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let delta: Delta
        struct Delta: Decodable {
            let content: String?
            let toolCalls: [ToolCallDelta]?
            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }
    }
    struct ToolCallDelta: Decodable {
        let index: Int
        let id: String?
        let function: FunctionDelta?
        struct FunctionDelta: Decodable {
            let name: String?
            let arguments: String?
        }
    }
}

private struct OAIChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable {
            let content: String?
            let toolCalls: [ToolCallBlock]?
            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }
        struct ToolCallBlock: Decodable {
            let id: String
            let function: FunctionBlock
            struct FunctionBlock: Decodable {
                let name: String
                let arguments: String
            }
        }
    }
}
