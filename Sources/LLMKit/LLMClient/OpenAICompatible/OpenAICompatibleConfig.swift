//
//  OpenAICompatibleConfig.swift
//  LLMKit
//
//  Bring-your-own OpenAI-compatible endpoint (custom base URL + API key + model).
//  When an LLMClient is created with this config, chat/streamChat talk directly to the
//  endpoint's /chat/completions instead of the hosted LLMServer, and the credits/auth
//  surface becomes inert (no settlement, no /credits, no /auth).
//

import Foundation

public struct OpenAICompatibleConfig: Sendable {
    /// The OpenAI-compatible API root, e.g. `http://localhost:1234/v1` or `https://api.openai.com/v1`.
    public let baseURL: URL
    /// Bearer token sent as `Authorization: Bearer <apiKey>`.
    public let apiKey: String
    /// Model identifier passed verbatim to the endpoint.
    public let model: String
    /// System prompt injected as the first message (the hosted server normally did this server-side).
    public let systemPrompt: String

    public init(baseURL: URL, apiKey: String, model: String, systemPrompt: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
    }
}
