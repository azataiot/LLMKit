//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

import Foundation
import LLMCore
import OpenAI


extension LLMClient {
    public func chat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        system: String? = nil,
        text: String,
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> APIResponse<ChatMessageContent> {
        if let cfg = openAIConfig {
            return try await chatOpenAICompatible(
                system: system ?? cfg.systemPrompt,
                messages: [.init(role: .user, content: text)],
                tools: tools
            )
        }
        let preparedMessages = try await prepareUploadFiles(for: (
            system == nil ? [] : [
                .init(role: .system, content: system!),
            ]
        ) + [
            .init(role: .user, content: text)
        ])

        return try await networking.post(
            "/chat",
            body: ChatRequest(
                model: model,
                messages: preparedMessages,
                metadata: metadata,
                agentID: agentID,
                tools: tools
            )
        )
    }

    public func chat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        messages: [ChatMessageContent],
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> APIResponse<ChatMessageContent> {
        if let cfg = openAIConfig {
            return try await chatOpenAICompatible(system: cfg.systemPrompt, messages: messages, tools: tools)
        }
        let preparedMessages = try await prepareUploadFiles(for: messages)

        return try await networking.post(
            "/chat",
            body: ChatRequest(model: model, messages: preparedMessages, metadata: metadata, agentID: agentID, tools: tools)
        )
    }

    public func streamChat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        system: String? = nil,
        text: String,
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        if let cfg = openAIConfig {
            return try await streamChatOpenAICompatible(
                system: system ?? cfg.systemPrompt,
                messages: [.init(role: .user, content: text)],
                tools: tools
            )
        }
        let preparedMessages = try await prepareUploadFiles(for: (
            system == nil ? [] : [
                .init(role: .system, content: system!),
            ]
        ) + [
            .init(role: .user, content: text)
        ])

        return try await networking.stream("/chat/stream", body: ChatRequest(
            model: model,
            messages: preparedMessages,
            metadata: metadata,
            agentID: agentID,
            tools: tools
        ))
    }

    public func streamChat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        messages: [ChatMessageContent],
        metadata: Metadata? = EmptyMetadata(),
        agentID: String? = nil,
        tools: [ToolSchema]? = nil
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        if let cfg = openAIConfig {
            return try await streamChatOpenAICompatible(system: cfg.systemPrompt, messages: messages, tools: tools)
        }
        let preparedMessages = try await prepareUploadFiles(for: messages)

        return try await networking.stream("/chat/stream", body: ChatRequest(model: model, messages: preparedMessages, metadata: metadata, agentID: agentID, tools: tools))
    }
    
//    public func streamChat(
//        model: SupportedModel,
//        messages: [ChatMessageContent],
//        onUpdateMessage: (@escaping (ChatMessageContent) -> Void),
//        onSettlement: (@escaping (ChatResponse) -> Void
//    ) async throws {
//        for try await result: StreamChatResponse<ChatStreamResult> in try await networking.stream("/chat/stream", body: ChatRequest(model: model, messages: messages)) {
//            switch result {
//                case .message(let message):
//                    
//                case .settlement(let settlement):
//                    
//            }
//        }
//    }
}
