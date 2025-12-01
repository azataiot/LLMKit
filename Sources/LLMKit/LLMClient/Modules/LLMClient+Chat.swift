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
        metadata: Metadata? = EmptyMetadata()
    ) async throws -> APIResponse<ChatMessageContent> {
        try await networking.post(
            "/chat",
            body: ChatRequest(
                model: model,
                messages: (
                    system == nil ? [] : [
                        .init(role: .system, content: system!),
                    ]
                ) + [
                    .init(role: .user, content: text)
                ],
                metadata: metadata
            )
        )
    }

    public func chat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        messages: [ChatMessageContent],
        metadata: Metadata? = EmptyMetadata()
    ) async throws -> APIResponse<ChatMessageContent> {
        try await networking.post(
            "/chat",
            body: ChatRequest(model: model, messages: messages, metadata: metadata)
        )
    }

    public func streamChat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        system: String? = nil,
        text: String,
        metadata: Metadata? = EmptyMetadata()
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        try await networking.stream("/chat/stream", body: ChatRequest(
            model: model,
            messages: (
                system == nil ? [] : [
                    .init(role: .system, content: system!),
                ]
            ) + [
                .init(role: .user, content: text)
            ],
            metadata: metadata
        ))
    }

    public func streamChat<Metadata: Codable & Equatable & Sendable>(
        model: SupportedModel,
        messages: [ChatMessageContent],
        metadata: Metadata? = EmptyMetadata()
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        try await networking.stream("/chat/stream", body: ChatRequest(model: model, messages: messages, metadata: metadata))
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
