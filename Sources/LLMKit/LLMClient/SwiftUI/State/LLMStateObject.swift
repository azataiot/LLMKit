//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 1/14/26.
//

#if canImport(SwiftUI)
import SwiftUI

import ChocofordEssentials
import LLMCore
import Logging
import StoreKit


@MainActor
public final class LLMStreamingStateObject: ObservableObject, @MainActor StreamingMessageState {
    @Published public var id: String
    @Published public var conversationID: Conversation.ID
    @Published public var content: String
    @Published public var files: [ChatMessageContent.File]
    /// 当前正在 stream 的 assistant 消息附带的 tool calls (空 = 终态/纯回复)。
    @Published public var toolCalls: [ToolCall]
    @Published public var isFinished: Bool

    public init(conversationID: Conversation.ID) {
        self.id = UUID().uuidString
        self.conversationID = conversationID
        self.content = ""
        self.files = []
        self.toolCalls = []
        self.isFinished = false
    }
}


@MainActor
public final class LLMStateObject: ObservableObject, @MainActor LLMStatable {
    public typealias StreamingState = LLMStreamingStateObject

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

    public internal(set) var streamingStore: StreamingStore<LLMStreamingStateObject> = .init()

    @Published public internal(set) var creditsInfo: CreditsInfo? = nil

    var inflightTasks: [String: Task<Void, Error>] = [:]

    /// 取消指定 conversation 当前正在跑的生成。Idempotent: 没有 in-flight 时是 no-op。
    /// partial 已 commit 进 conversation.messages 的内容会被保留, 计费按已 settlement 的算。
    public func cancelGeneration(conversationID: String) {
        self._cancelGeneration(conversationID: conversationID)
    }

    /// Computed property for backward compatibility
    public var credits: Double {
        creditsInfo?.balance ?? 0
    }

    // @discardableResult
    public func handlePurchase(verificationResult: VerificationResult<StoreKit.Transaction>) async throws {
        try await self._handlePurchase(verificationResult: verificationResult)

    }
    
    public func configurePersistenceProvider(_ provider: PersistenceProvider) {
        self._configurePersistenceProvider(provider)
    }

    public func createConversation<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye = .normal,
        model: SupportedModel,
        agentConfig: AgentConfig = .chat,
        appendingPrompt: String? = nil,
        messages: [ChatMessage],
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        context invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._createConversation(
            id: id,
            type: type,
            model: model,
            agentConfig: agentConfig,
            appendingPrompt: appendingPrompt,
            messages: messages,
            stream: stream,
            metadata: metadata,
            invocationContext: invocationContext,
            replyTransformer: replyTransformer
        )
    }

    public func sendMessage<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        context invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._sendMessage(
            to: conversationID,
            model: model,
            message: message,
            stream: stream,
            metadata: metadata,
            invocationContext: invocationContext,
            replyTransformer: replyTransformer
        )
    }

    public func regenerateMessage<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        context invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        try await self._regenerateMessage(
            in: conversationID,
            fromMessageID: fromMessageID,
            model: model,
            stream: stream,
            metadata: metadata,
            invocationContext: invocationContext,
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


#endif
