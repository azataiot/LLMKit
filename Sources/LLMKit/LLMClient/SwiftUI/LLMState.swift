//
//  LLMState.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

#if canImport(SwiftUI)
import SwiftUI

import ChocofordEssentials
import LLMCore
import Logging

@MainActor
public final class LLMStateObject: ObservableObject, LLMStatable {
    let logger = Logger(label: "LLMStateObject")
    var llmClient: LLMClient
    var toolRegistry: ToolRegistry
    var persistenceProvider: (any PersistenceProvider)?

    public init(llmClient: LLMClient, toolRegistry: ToolRegistry = ToolRegistry(), persistenceProvider: PersistenceProvider?) {
        self.llmClient = llmClient
        self.toolRegistry = toolRegistry
        self.persistenceProvider = persistenceProvider
    }

    @Published public internal(set) var isAuthenticated: Bool = false

    @Published public internal(set) var conversations: Loadable<[Conversation]> = .notRequested

    @Published public internal(set) var creditsInfo: CreditsInfo? = nil

    /// Computed property for backward compatibility
    public var credits: Double {
        creditsInfo?.balance ?? 0
    }

    public func configurePersistenceProvider(_ provider: PersistenceProvider) {
        self._configurePersistenceProvider(provider)
    }

    public func createConversation<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye = .normal,
        model: SupportedModel,
        agentConfig: AgentConfig = .chat,
        systemMessage: String? = nil,
        messages: [ChatMessage],
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._createConversation(
            id: id,
            type: type,
            model: model,
            agentConfig: agentConfig,
            systemMessage: systemMessage,
            messages: messages,
            stream: stream,
            metadata: metadata,
            replyTransformer: replyTransformer
        )
    }

    public func sendMessage<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._sendMessage(
            to: conversationID,
            model: model,
            message: message,
            stream: stream,
            metadata: metadata,
            replyTransformer: replyTransformer
        )
    }

    public func regenerateMessage<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._regenerateMessage(
            in: conversationID,
            fromMessageID: fromMessageID,
            model: model,
            stream: stream,
            metadata: metadata,
            replyTransformer: replyTransformer
        )
    }

    public func temporaryChat(
        model: SupportedModel,
        messages: [ChatMessage],
        stream: Bool = true,
        onUpdate: @escaping (_ message: ChatMessage) async throws -> Void,
        onFirstReply: @escaping (_ message: ChatMessage) async throws -> Void = { _ in },
    ) async throws -> ChatMessage {
        try await self._temporaryChat(
            model: model,
            messages: messages,
            stream: stream,
            onUpdate: onUpdate,
            onFirstReply: onFirstReply
        )
    }

    public func refreshConversations() async {
        await self._refreshConversations()
    }

    public func getConversation(by id: String) -> Conversation? {
        self._getConversation(by: id)
    }
}


@available(macOS 14.0, iOS 17.0, *)
@MainActor
@Observable
public final class LLMState: LLMStatable {
    let logger = Logger(label: "LLMState")
    var llmClient: LLMClient
    var toolRegistry: ToolRegistry
    var persistenceProvider: (any PersistenceProvider)?

    public init(llmClient: LLMClient, toolRegistry: ToolRegistry = ToolRegistry(), persistenceProvider: PersistenceProvider?) {
        self.llmClient = llmClient
        self.toolRegistry = toolRegistry
        self.persistenceProvider = persistenceProvider
    }
    
    public internal(set) var isAuthenticated: Bool = false
    public internal(set) var conversations: Loadable<[Conversation]> = .notRequested
    public internal(set) var creditsInfo: CreditsInfo? = nil

    /// Computed property for backward compatibility
    public var credits: Double {
        creditsInfo?.balance ?? 0
    }
    
    public func configurePersistenceProvider(_ provider: PersistenceProvider) {
        self._configurePersistenceProvider(provider)
    }

    public func createConversation<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye = .normal,
        model: SupportedModel,
        agentConfig: AgentConfig = .chat,
        systemMessage: String? = nil,
        messages: [ChatMessage],
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._createConversation(
            id: id,
            type: type,
            model: model,
            agentConfig: agentConfig,
            systemMessage: systemMessage,
            messages: messages,
            stream: stream,
            metadata: metadata,
            replyTransformer: replyTransformer
        )
    }

    public func sendMessage<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._sendMessage(
            to: conversationID,
            model: model,
            message: message,
            stream: stream,
            metadata: metadata,
            replyTransformer: replyTransformer
        )
    }

    public func regenerateMessage<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._regenerateMessage(
            in: conversationID,
            fromMessageID: fromMessageID,
            model: model,
            stream: stream,
            metadata: metadata,
            replyTransformer: replyTransformer
        )
    }

    @discardableResult
    public func temporaryChat(
        model: SupportedModel,
        messages: [ChatMessage],
        stream: Bool = true,
        onUpdate: @escaping (_ message: ChatMessage) async throws -> Void,
        onFirstReply: @escaping (_ message: ChatMessage) async throws -> Void = { _ in },
    ) async throws -> ChatMessage {
        try await self._temporaryChat(
            model: model,
            messages: messages,
            stream: stream,
            onUpdate: onUpdate,
            onFirstReply: onFirstReply
        )
    }

    public func refreshConversations() async {
        await self._refreshConversations()
    }

    public func deleteConversation(_ conversationID: String) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        // Remove from local state
        await MainActor.run {
            self.conversations.transform {
                $0.remove(at: index)
            }
        }

        // Persist the deletion
        try await persistenceProvider?.updateConversation(
            action: .delete(conversationID)
        )
    }

    public func getConversation(by id: String) -> Conversation? {
        self._getConversation(by: id)
    }
}

#endif // canImport(SwiftUI)
