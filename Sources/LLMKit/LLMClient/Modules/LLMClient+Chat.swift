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
    public func chat(
        model: SupportedModel,
        system: String? = nil,
        text: String
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
                ]
            )
        )
    }
    
    public func chat(
        model: SupportedModel,
        messages: [ChatMessageContent]
    ) async throws -> APIResponse<ChatMessageContent> {
        try await networking.post(
            "/chat",
            body: ChatRequest(model: model, messages: messages)
        )
    }
    
    public func streamChat(
        model: SupportedModel,
        system: String? = nil,
        text: String
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        try await networking.stream("/chat/stream", body: ChatRequest(model: model, messages: (
            system == nil ? [] : [
                .init(role: .system, content: system!),
            ]
        ) + [
            .init(role: .user, content: text)
        ]))
    }
    
    public func streamChat(
        model: SupportedModel,
        messages: [ChatMessageContent]
    ) async throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        try await networking.stream("/chat/stream", body: ChatRequest(model: model, messages: messages))
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
