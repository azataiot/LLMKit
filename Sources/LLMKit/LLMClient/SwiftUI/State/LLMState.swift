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
import StoreKit

@available(macOS 14.0, iOS 17.0, *)
@MainActor
@Observable
public final class LLMStreamingState: @MainActor StreamingMessageState {
    public var id: String
    public var conversationID: Conversation.ID
    public var content: String
    public var files: [ChatMessageContent.File]
    /// 当前正在 stream 的 assistant 消息附带的 tool calls (空 = 终态/纯回复)。
    public var toolCalls: [ToolCall]
    public var isFinished: Bool

    public init(conversationID: Conversation.ID) {
        self.id = UUID().uuidString
        self.conversationID = conversationID
        self.content = ""
        self.files = []
        self.toolCalls = []
        self.isFinished = false
    }
}

@available(macOS 14.0, iOS 17.0, *)
@MainActor
@Observable
public final class LLMState:  @MainActor LLMStatable {
    public typealias StreamingState = LLMStreamingState

    let logger = Logger(label: "LLMState")
    var llmClient: LLMClient
    /// 暴露给外部只读: UI 渲染历史消息里的 toolCalls 时, 用它按 name 反查 Tool 拿 displayName。
    public internal(set) var toolRegistry: ToolRegistry
    var persistenceProvider: (any PersistenceProvider)?

    public init(llmClient: LLMClient, toolRegistry: ToolRegistry = ToolRegistry(), persistenceProvider: PersistenceProvider?) {
        self.llmClient = llmClient
        self.toolRegistry = toolRegistry
        self.persistenceProvider = persistenceProvider
        // 默认 approval handler 桥到 publisher 模式: AgentExecutor 调到这个 closure 时,
        // 内部 await 一个 continuation, 同时把 request 发布到 pendingApprovalRequest;
        // SwiftUI 看到字段变化弹 sheet, 用户点击后调 respondToApproval(_:), continuation
        // resume, AgentExecutor 立刻拿到 decision 继续。
        // 用户可以重新赋值 toolApprovalHandler 走 closure 路径覆盖默认 bridge。
        self.toolApprovalHandler = nil
        self.toolApprovalHandler = { [weak self] request in
            guard let self else { return .deny(reason: "client gone") }
            return await self.awaitApprovalDecision(request)
        }
    }

    public internal(set) var isAuthenticated: Bool = false
    public internal(set) var conversations: Loadable<[Conversation]> = .notRequested
    public internal(set) var streamingStore: StreamingStore<LLMStreamingState> = .init()
    public internal(set) var creditsInfo: CreditsInfo? = nil
    var inflightTasks: [String: Task<Void, Error>] = [:]

    /// 当前等待 approval 的请求。SwiftUI 直接用 `.sheet(item: ...)` 监听这个字段。
    /// 同一时刻只有一条 pending (sequential approval), 用户调 `respondToApproval(_:)` 返回决策。
    public internal(set) var pendingApprovalRequest: ToolApprovalRequest?

    @ObservationIgnored
    private var pendingApprovalContinuation: CheckedContinuation<ToolApprovalDecision, Never>?

    /// 客户端 UI 弹完 approval sheet 后调这个返回决策。bridge 内部的 continuation resume,
    /// AgentExecutor 那边的 await 立即拿到结果继续后续 tool 执行。
    public func respondToApproval(_ decision: ToolApprovalDecision) {
        pendingApprovalContinuation?.resume(returning: decision)
        pendingApprovalContinuation = nil
        pendingApprovalRequest = nil
    }

    /// Tool approval handler。默认值 = bridge 到 publisher 模式 (`pendingApprovalRequest` +
    /// `respondToApproval(_:)`)。普通 SwiftUI 客户端不要碰这个; 非 UI / 高级场景可重赋值
    /// 走 closure 路径, 但那样 publisher 不再有效。
    public var toolApprovalHandler: ToolApprovalHandler?

    /// Bridge 函数: 把 closure-based handler 转成 publisher 模式。
    /// withTaskCancellationHandler 让 cancel 链路触发时 deny + 清理 pending state, 否则
    /// pendingApprovalRequest 会卡住, 下次再开 conversation 时仍然显示旧 sheet。
    private func awaitApprovalDecision(_ request: ToolApprovalRequest) async -> ToolApprovalDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ToolApprovalDecision, Never>) in
                self.pendingApprovalContinuation = continuation
                self.pendingApprovalRequest = request
            }
        } onCancel: {
            Task { @MainActor in
                self.pendingApprovalContinuation?.resume(returning: .deny(reason: "cancelled"))
                self.pendingApprovalContinuation = nil
                self.pendingApprovalRequest = nil
            }
        }
    }

    /// 取消指定 conversation 当前正在跑的生成。Idempotent: 没有 in-flight 时是 no-op。
    /// partial 已 commit 进 conversation.messages 的内容会被保留, 计费按已 settlement 的算。
    public func cancelGeneration(conversationID: String) {
        self._cancelGeneration(conversationID: conversationID)
    }

    /// 把会话截断到指定 message。inclusive=true 连同 fromMessageID 自身一起删, false 只删它之后的。
    /// 内部会先 cancel 当前 in-flight 生成。
    public func truncateConversation(
        in conversationID: String,
        fromMessageID: String,
        inclusive: Bool
    ) async throws {
        try await self._truncateConversation(
            in: conversationID,
            fromMessageID: fromMessageID,
            inclusive: inclusive
        )
    }

    /// 清空会话内容, 保留 system message。完全重置请用 deleteConversation + createConversation。
    public func clearConversation(_ conversationID: String) async throws {
        try await self._clearConversation(conversationID)
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
        type: Conversation.ConversationTpye = .regular,
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
