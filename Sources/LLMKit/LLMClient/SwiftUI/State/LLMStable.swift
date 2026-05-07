//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 11/25/25.
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

@MainActor
protocol LLMStatable: AnyObject {
    associatedtype StreamingState: StreamingMessageState

    var logger: Logger { get }
    var llmClient: LLMClient { get }
    var toolRegistry: ToolRegistry { get }
    var isAuthenticated: Bool { get set }
    var conversations: Loadable<[Conversation]> { get set }
    var streamingStore: StreamingStore<StreamingState> { get set }

    var creditsInfo: CreditsInfo? { get set }
    var persistenceProvider: PersistenceProvider? { get set }

    /// 同一会话同时只允许一个 in-flight 生成, 注册的是 _sendMessage 的内层 Task,
    /// `cancelGeneration(conversationID:)` 找到这个 Task 调 cancel(),
    /// cancellation 沿 URLSession SSE 关闭传到服务端, 上游 OpenRouter 连接被关。
    var inflightTasks: [String: Task<Void, Error>] { get set }

    /// Tool approval handler: tool 声明 `requiresApproval` 时, 执行前 raise 给客户端弹 UI 等决策。
    /// nil = 自动 approve (向后兼容)。客户端 closure 内部自己负责 UI、cancel 响应、跨会话持久化。
    var toolApprovalHandler: ToolApprovalHandler? { get set }

    /// Computed property for backward compatibility
    var credits: Double { get }
    
    func handlePurchase(verificationResult: VerificationResult<Transaction>) async throws

    func createConversation<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye,
        model: SupportedModel,
        agentConfig: AgentConfig,
        appendingPrompt: String?,
        messages: [ChatMessage],
        stream: Bool,
        metadata: Metadata,
        context invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws

    func sendMessage<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool,
        metadata: Metadata,
        context invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws

    func regenerateMessage<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool,
        metadata: Metadata,
        context invocationContext: (any ChatInvocationContext)?,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)?
    ) async throws

    func temporaryChat(
        model: SupportedModel,
        messages: [ChatMessage],
        stream: Bool,
        onUpdate: @escaping @Sendable (_ message: ChatMessage) async throws -> Void,
        onFirstReply: @escaping @Sendable (_ message: ChatMessage) async throws -> Void,
    ) async throws -> ChatMessage

    func refreshConversations() async
}
struct ConversationNotReadyError: Error {}
struct ConversationNotFoundError: Error {}
struct ChatMessageNotFoundError: Error {}

/// CancellationError 是 Swift Task cancel 的标准抛出, URLError(.cancelled) 是 URLSession
/// 在被 cancel 时抛的 (异步 stream API 不一定包成 CancellationError)。两者都是用户主动
/// 取消的语义, 应该一视同仁吞掉。
fileprivate func isUserCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

extension LLMStatable {
    func updateCreditsInfo(_ creditsInfo: CreditsInfo) {
        self.creditsInfo = creditsInfo
    }

    /// 在 truncate/clear 这种结构性修改前调一下: cancel 当前生成 + 等任务真正退出再继续,
    /// 避免 in-flight Task 跟我们这边修改 conversations 同时写 race。
    /// `_cancelGeneration` 是 fire-and-forget (UI cancel 按钮用), 这里要等。
    fileprivate func cancelAndAwait(conversationID: String) async {
        guard let task = inflightTasks[conversationID] else { return }
        task.cancel()
        _ = try? await task.value
        inflightTasks[conversationID] = nil
    }

    /// 把会话截断到指定 message。inclusive=true 时连同 fromMessageID 自身一起删,
    /// false 时只删它之后的。常用于"在这条消息处重新生成 / 分支"场景。
    /// 截断前会先 cancel 当前 in-flight 生成 (如果有), 等它停稳再修改。
    func _truncateConversation(
        in conversationID: String,
        fromMessageID: String,
        inclusive: Bool
    ) async throws {
        guard case .loaded = conversations else { throw ConversationNotReadyError() }
        guard let convIndex = conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }
        guard let msgIndex = conversations.value?[convIndex].messages.firstIndex(where: { $0.id == fromMessageID }) else {
            throw ChatMessageNotFoundError()
        }

        await cancelAndAwait(conversationID: conversationID)

        let cutIndex = inclusive ? msgIndex : msgIndex + 1
        let messagesToRemove = Array(conversations.value![convIndex].messages[cutIndex...])
        let removedIDs = messagesToRemove.map(\.id)

        await MainActor.run {
            self.conversations.transform {
                $0[convIndex].messages.removeSubrange(cutIndex...)
            }
        }

        if !removedIDs.isEmpty {
            try await persistenceProvider?.updateConversation(
                action: .update(conversationID, .delete(removedIDs))
            )
        }
    }

    /// 清空会话内容, 但**保留 system message** (它是 conversation 配置的一部分,
    /// 没了下次发送会拿不到 prompt)。想完全重置请用 deleteConversation + createConversation。
    func _clearConversation(_ conversationID: String) async throws {
        guard case .loaded = conversations else { throw ConversationNotReadyError() }
        guard let convIndex = conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        await cancelAndAwait(conversationID: conversationID)

        let messages = conversations.value![convIndex].messages
        let removedIDs = messages.compactMap { msg -> String? in
            if case .content(let c) = msg, c.role == .system { return nil }
            return msg.id
        }

        await MainActor.run {
            self.conversations.transform {
                $0[convIndex].messages.removeAll { msg in
                    if case .content(let c) = msg, c.role == .system { return false }
                    return true
                }
            }
        }

        if !removedIDs.isEmpty {
            try await persistenceProvider?.updateConversation(
                action: .update(conversationID, .delete(removedIDs))
            )
        }
    }

    /// 取消对应 conversation 当前的生成。partial 已 commit 的消息不会被回滚。
    /// 计费按已收到的 settlement 算 (上游 OpenRouter 在断流前通常会回最后那条 usage chunk)。
    public func _cancelGeneration(conversationID: String) {
        guard let task = inflightTasks[conversationID] else { return }
        task.cancel()
        inflightTasks[conversationID] = nil
    }
    
    
    func _handlePurchase(verificationResult: VerificationResult<Transaction>) async throws {
        switch verificationResult {
            case .verified(let signed):
                if let groupID = signed.subscriptionGroupID {
                    // subscription
                    await self.llmClient.restore(groupID: groupID)
                } else {
                    _ = try await llmClient.addCredits(
                        transactionSignedData: verificationResult.jwsRepresentation
                    )
                }
            case .unverified(_, let err):
                throw err
        }
    }
    
    func _configurePersistenceProvider(_ provider: PersistenceProvider) {
        self.persistenceProvider = provider
        Task {
            await self._refreshConversations()
        }
    }
    
    func _getConversation(by id: String) -> Conversation? {
        return conversations.value?.first { $0.id == id }
    }

    func _createConversation<Metadata: Codable & Equatable & Sendable>(
        id: String,
        type: Conversation.ConversationTpye = .regular,
        model: SupportedModel,
        agentConfig: AgentConfig = .chat,
        appendingPrompt: String? = nil,
        messages: [ChatMessage],
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }
        guard self.conversations.value?.first(where: { $0.id == id }) == nil else {
            throw NSError(domain: "LLMStatable", code: 1, userInfo: [NSLocalizedDescriptionKey: "Conversation with ID \(id) already exists"])
        }

        // Create new conversation
        let newConversation: Conversation = .init(
            id: id,
            type: type,
            agentConfig: agentConfig,
            title: "New conversation",
            createdAt: .now,
            lastChatAt: .now
        )
        await MainActor.run {
            self.conversations.transform {
                $0.insert(newConversation, at: 0)
            }
        }
        try await persistenceProvider?.updateConversation(action: .insert(newConversation))

        // Generate and add system message
        guard let index = self.conversations.value?.firstIndex(where: { $0.id == id }) else {
            throw ConversationNotFoundError()
        }

        // Build complete system prompt
        var systemPromptParts: [String] = []

        // 1. AgentConfig prompt (system prompt + strategy instructions)
        let agentPrompt = agentConfig.prompt
        if !agentPrompt.isEmpty {
            systemPromptParts.append(agentPrompt)
        }

        // 2. Tools description (if agent uses tools)
        if !agentConfig.tools.isEmpty {
            let toolsDesc = await toolRegistry.generateToolsDescription(for: agentConfig.tools)
            if !toolsDesc.isEmpty {
                systemPromptParts.append(toolsDesc)
            }
        }

        // 3. User-provided appending prompt (if any) appended last
        if let appendingPrompt = appendingPrompt, !appendingPrompt.isEmpty {
            systemPromptParts.append(appendingPrompt)
        }

        // Combine all parts and add as system message
        if !systemPromptParts.isEmpty {
            let completeSystemPrompt = systemPromptParts.joined(separator: "\n\n")
            let systemMsgContent = ChatMessageContent(
                id: UUID().uuidString,
                role: .system,
                content: completeSystemPrompt
            )
            let systemMsg = ChatMessage.content(systemMsgContent)
            await MainActor.run {
                self.conversations.transform {
                    $0[index].messages.append(systemMsg)
                }
            }
            try await persistenceProvider?.updateConversation(
                action: .update(id, .insert([systemMsg]))
            )
        }

        // Generate title asynchronously if there's a user message
        if let firstUserMessage = messages.first, let content = firstUserMessage.content, !content.isEmpty {
            Task {
                logger.info("Generating title for new conversation...")
                let result = try await llmClient.chat(
                    model: .gpt35Turbo,
                    system: """
                    You are a conversation title generator. Generate a concise, descriptive title (3-8 words) based on the user's first message.

                    Rules:
                    - Return ONLY the title text, no quotes, no extra explanation
                    - Keep it short and clear
                    - Capture the main topic or intent
                    - Use title case

                    Example:
                    User: "How do I deploy a Swift app to the App Store?"
                    Title: Deploy Swift App to App Store
                    """,
                    text: content
                )

                if let credits = result.credits {
                    self.updateCreditsInfo(CreditsInfo(
                        balance: credits.remains,
                        subscription: nil,
                        purchasedCredits: 0
                    ))
                }

                let title = result.data?.content ?? "New conversation"
                
                try await persistenceProvider?.updateConversation(
                    action: .update(id, .updateTitle(title))
                )
                await MainActor.run {
                    if let index = self.conversations.value?.firstIndex(where: { $0.id == id }) {
                        self.conversations.transform {
                            $0[index].title = title
                        }
                    }
                }
            }
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == id }) else {
            throw ConversationNotFoundError()
        }

        // Insert all messages except the last one as context
        if messages.count > 1 {
            let contextMessages = messages.dropLast()
            await MainActor.run {
                self.conversations.transform {
                    $0[index].messages.append(contentsOf: contextMessages)
                }
            }
            try await persistenceProvider?.updateConversation(
                action: .update(id, .insert(Array(contextMessages)))
            )
        }
        
        // Send only the last message to get a response
        if let lastMessage = messages.last {
            try await _sendMessage(
                to: id,
                model: model,
                message: lastMessage,
                stream: stream,
                metadata: metadata,
                invocationContext: invocationContext,
                replyTransformer: replyTransformer
            )
        }
    }

    func _regenerateMessage<Metadata: Codable & Equatable & Sendable>(
        in conversationID: String,
        fromMessageID: String,
        model: SupportedModel,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        // Find the assistant message to regenerate
        guard let assistantMessageIndex = self.conversations.value![index].messages.firstIndex(where: { $0.id == fromMessageID }) else {
            throw NSError(domain: "LLMStatable", code: 2, userInfo: [NSLocalizedDescriptionKey: "Message with ID \(fromMessageID) not found"])
        }

        // Find the user message that corresponds to this assistant message
        let messagesBeforeAssistant = self.conversations.value![index].messages.prefix(upTo: assistantMessageIndex)
        guard let userMessageIndex = messagesBeforeAssistant.lastIndex(where: {
            if case .content(let content) = $0 {
                return content.role == .user
            }
            return false
        }) else {
            throw NSError(domain: "LLMStatable", code: 3, userInfo: [NSLocalizedDescriptionKey: "No user message found before the assistant message"])
        }

        let userMessage = self.conversations.value![index].messages[userMessageIndex]

        // Remove all messages from the user message onwards (including the user message itself)
        let messagesToRemove = Array(self.conversations.value![index].messages.suffix(from: userMessageIndex))
        await MainActor.run {
            self.conversations.transform {
                $0[index].messages.removeSubrange(userMessageIndex...)
            }
        }

        // Persist the removal
        try await persistenceProvider?.updateConversation(
            action: .update(conversationID, .delete(messagesToRemove.map { $0.id }))
        )

        // Resend the user message to generate a new response
        try await _sendMessage(
            to: conversationID,
            model: model,
            message: userMessage,
            stream: stream,
            metadata: metadata,
            invocationContext: invocationContext,
            replyTransformer: replyTransformer
        )
    }

    func _sendMessage<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        // 把整个生成主体包成一个 child Task, 注册到 inflightTasks。cancelGeneration
        // 时取消这个 Task → 内部 await 抛 CancellationError → URLSession SSE 关闭 →
        // 服务端 onTermination 关 OpenRouter 连接。partial 已 commit 的消息保留。
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self._sendMessageBody(
                to: conversationID,
                model: model,
                message: message,
                stream: stream,
                metadata: metadata,
                invocationContext: invocationContext,
                replyTransformer: replyTransformer
            )
        }
        self.inflightTasks[conversationID] = task
        defer { self.inflightTasks[conversationID] = nil }

        do {
            try await task.value
        } catch let error where isUserCancellationError(error) {
            // 用户主动取消, 不向上抛。loading 占位移除掉避免 UI 一直转。
            await MainActor.run {
                if let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                    self.conversations.transform {
                        $0[i].messages.removeAll(where: {
                            if case .loading = $0 { return true } else { return false }
                        })
                    }
                }
            }
            self.logger.info("sendMessage cancelled for conversation \(conversationID)")
        }
    }


    /// 真正的发送主体, 以前是 _sendMessage 的整个 body, 现在被包到可取消的 child Task 里。
    func _sendMessageBody<Metadata: Codable & Equatable & Sendable>(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool = true,
        metadata: Metadata = EmptyMetadata(),
        invocationContext: (any ChatInvocationContext)? = nil,
        replyTransformer: ((_ assistantMessage: ChatMessage) async throws -> ChatMessage)? = nil
    ) async throws {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        await MainActor.run {
            self.conversations.transform {
                $0[index].messages.append(message)
            }
        }
        
        let loadingResponseMessage = ChatMessage.loading()
        let canStream = model.supportsStreaming
        await MainActor.run {
            self.conversations.transform {
                $0[index].messages.append(loadingResponseMessage)
            }
        }
        await MainActor.run {
            let streamState = self.streamingStore.stream(for: conversationID)
            streamState.id = UUID().uuidString
            streamState.content = ""
            streamState.files = []
            streamState.toolCalls = []
            streamState.isFinished = false
        }
        
        do {
            // Upload files if any
            let conversationAfterUploading = try await llmClient.prepareUploadFiles(
                for: self.conversations.value![index]
            )
            
            await MainActor.run {
                self.conversations.transform {
                    $0[index] = conversationAfterUploading
                }
            }
            
            logger.info("Sending message to conversation \(conversationID), model: \(model.rawValue), stream: \(stream), canStream: \(canStream)")
            for message in self.conversations.value![index].messages.contentMessages {
                logger.info("- \(String(describing: message).prefix(1024))")
            }
            logger.info("Sending message end")

            let conversation = self.conversations.value![index]
            let executor = AgentExecutor(llmProvider: llmClient, toolRegistry: toolRegistry)

            // Use AgentExecutor for all interactions (native tool-use; no separate onStep callback).
            // 流里会拿到三种 ChatMessageContent:
            //   - role=.assistant + toolCalls 非空 → 中间一轮(模型说话+决定调工具)
            //   - role=.tool                   → 工具执行结果
            //   - role=.assistant + 无 toolCalls → 终态(最终回复)
            let llmClient = self.llmClient
            let approvalHandler = self.toolApprovalHandler
            let responseStream = try await executor.execute(
                conversationID: conversation.id,
                agentConfig: conversation.agentConfig,
                contextMessages: conversation.messages.contentMessages,
                model: model,
                metadata: metadata,
                invocationContext: invocationContext,
                toolResultTransformer: { toolMessage in
                    // 工具产出的图片(base64) 自动走 R2, 跟 user message 同一条 prepareUploadFiles 路径
                    try await llmClient.prepareUploadFiles(for: toolMessage)
                },
                toolApprovalHandler: approvalHandler
            )

            // Consume the stream
            var responseMessage: ChatMessage?
            // 跟踪当前正在 stream 的 assistant 消息 id, 切到下一条 assistant / 收到 tool 结果时
            // 把上一条提交进对话历史。
            var streamingAssistantID: String?
            var committedIDs = Set<String>()
            // 持有最近一次 yield 出来的 assistant chunk 原件 (含 usage)。
            // streamState 只是 UI 投影没有 usage 字段, 提交时必须用 chunk 本身才不丢计费。
            var lastAssistantContent: ChatMessageContent?

            func commitMessageIfNeeded(_ message: ChatMessage) {
                guard !committedIDs.contains(message.id) else { return }
                committedIDs.insert(message.id)
                if let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                    self.conversations.transform { $0[i].messages.append(message) }
                }
            }

            func removeLoadingIfPresent() {
                if let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }),
                   let loaddingIndex = self.conversations.value![i].messages.firstIndex(where: { $0.id == loadingResponseMessage.id }) {
                    self.conversations.transform {
                        $0[i].messages.remove(at: loaddingIndex)
                    }
                }
            }

            for try await chatMessage in responseStream {
                responseMessage = chatMessage

                guard case .content(let content) = chatMessage else { continue }

                await MainActor.run {
                    removeLoadingIfPresent()

                    switch content.role {
                    case .tool:
                        // 切换流: 先把当前正在 stream 的 assistant 消息持久化 (如有), 再插入 tool 结果
                        if let prev = lastAssistantContent {
                            commitMessageIfNeeded(.content(prev))
                        }
                        lastAssistantContent = nil
                        streamingAssistantID = nil
                        commitMessageIfNeeded(.content(content))

                    case .assistant:
                        // 同 id 累加; 切 id 时提交前一条 streaming (用 chunk 原件, 含 usage)
                        if let prev = lastAssistantContent, prev.id != content.id {
                            commitMessageIfNeeded(.content(prev))
                        }
                        // 持有最新 chunk; settlement 之后的 chunk 会带 usage, 覆盖即可
                        lastAssistantContent = content
                        streamingAssistantID = content.id

                        let streamState = self.streamingStore.stream(for: conversationID)
                        streamState.id = content.id
                        streamState.content = content.content ?? ""
                        streamState.files = content.files ?? []
                        streamState.toolCalls = content.toolCalls ?? []
                        streamState.isFinished = false

                    default:
                        break
                    }
                }
            }

            // Cancel race: stream 可能在 inner task 还没消费下一个 chunk 时被打断 finish()
            // 而非 finish(throwing:), 这时下面的 guard 会拿到空 responseMessage 抛"No response"。
            // 但语义上这是 cancel 不是真正的"agent 没回复", 主动抛 CancellationError 让外层吞掉。
            try Task.checkCancellation()

            guard let finalMessage = responseMessage else {
                throw NSError(domain: "LLMStatable", code: 4, userInfo: [NSLocalizedDescriptionKey: "No response received from agent"])
            }

            // Extract and update credits from response
            if case .content(let content) = finalMessage, let creditsResult = content.usage {
                self.updateCreditsInfo(CreditsInfo(
                    balance: creditsResult.remains,
                    subscription: nil,
                    purchasedCredits: 0
                ))
            }
            
            // Apply transformer if provided
            var transformedMessage = finalMessage
            if let replyTransformer {
                transformedMessage = try await replyTransformer(transformedMessage)
            }
            
            if case .content(let content) = transformedMessage {
                await MainActor.run {
                    let streamState = self.streamingStore.stream(for: conversationID)
                    streamState.id = content.id
                    streamState.content = content.content ?? ""
                    streamState.files = content.files ?? []
                    streamState.toolCalls = content.toolCalls ?? []
                    streamState.isFinished = true
                }
            }

            await MainActor.run {
                if let i = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                    if let messageIndex = self.conversations.value![i].messages.firstIndex(where: { $0.id == transformedMessage.id }) {
                        self.conversations.transform {
                            $0[i].messages[messageIndex] = transformedMessage
                        }
                    } else {
                        self.conversations.transform {
                            $0[i].messages.append(transformedMessage)
                        }
                    }
                }
                self.streamingStore.removeStream(for: conversationID)
            }

            // Persist all new messages (user message + agent steps + final response)
            if let i = conversations.value?.firstIndex(where: { $0.id == conversationID }) {
                let newMessages = conversations.value![i].messages.suffix(from: conversations.value![i].messages.firstIndex(where: { $0.id == message.id }) ?? conversations.value![i].messages.endIndex)
                try await persistenceProvider?.updateConversation(
                    action: .update(conversationID, .insert(Array(newMessages)))
                )
            }
        } catch {
            if let loaddingMessageIndex = conversations.value![index].messages.firstIndex(where: {$0.id == loadingResponseMessage.id}) {
                await MainActor.run {
                    self.conversations.transform {
                        $0[index].messages.remove(at: loaddingMessageIndex)
                    }
                }
            }
            await MainActor.run {
                self.conversations.transform {
                    $0[index].messages.append(.error(UUID(), error.localizedDescription))
                }
            }
            await MainActor.run {
                self.streamingStore.removeStream(for: conversationID)
            }
            throw error
        }
    }
    
    func _refreshConversations() async {
        self.logger.info("Refreshing conversations from persistence provider: \(String(describing: persistenceProvider))")
        guard let persistenceProvider else {
            self.conversations.setAsLoaded(self.conversations.value ?? [])
            return
        }
        conversations.setIsLoading()
        do {
            let conversations = try await persistenceProvider.restoreConversations()
            self.conversations.setAsLoaded(conversations)
        } catch {
            self.conversations.setAsFailed(error)
        }
    }
    
    @discardableResult
    func _temporaryChat(
        model: SupportedModel,
        messages: [ChatMessage],
        stream: Bool = true,
        onUpdate: @escaping (_ message: ChatMessage) async throws -> Void,
        onFirstReply: @escaping (_ message: ChatMessage) async throws -> Void,
    ) async throws -> ChatMessage {
        if stream {
            let stream = try await llmClient.streamChat(
                model: model,
                messages: messages.contentMessages
            )
            var resMessage: ChatMessage?
            for try await result in stream {
                print("[_temporaryChat] Received stream result: \(String(describing: result).prefix(1024))")
                switch result {
                    case .message(let result):
                        if case .content(let partial) = resMessage {
                            let newContent = (partial.content ?? "") + (result.content ?? "")
                            resMessage?.content = newContent
                        } else {
                            resMessage = ChatMessage.content(result)
                            try await onFirstReply(resMessage!)
                        }
                    case .settlement(let creditsResult):
                        resMessage?.usage = creditsResult
                        // update credits
                        self.updateCreditsInfo(CreditsInfo(
                            balance: creditsResult.remains,
                            subscription: nil,
                            purchasedCredits: 0
                        ))
                }
                if let resMessage {
                    try await onUpdate(resMessage)
                }
            }
            guard resMessage != nil else {
                logger.error("No response message received in streaming")
                throw NSError() // Should never called
            }
            return resMessage!
        } else {
            fatalError()
            //            let result = try await self.llmClient.chat(
            //                model: model,
            //                messages: messages.contentMessages
            //            )
            //            logger.info("Chat result: \(String(describing: result).prefix(1024))")
            //
            //            if let error = result.error {
            //
            //            } else if let resMessage = result.data?.choices.first?.message {
            //                if let credits = result.credits {
            //                    self.updateCredits(credits.remains)
            //                }
            //                return resMessage
            //            }
        }
    }
}


public final class StreamingStore<State: StreamingMessageState> {
    private var streams: [Conversation.ID: State] = [:]

    public init() {}

    public func stream(for id: Conversation.ID) -> State {
        if let existing = streams[id] {
            return existing
        }

        let state = State(conversationID: id)
        streams[id] = state
        return state
    }

    public func removeStream(for id: Conversation.ID) {
        streams[id] = nil
    }

    public func streamIfExists(for id: Conversation.ID) -> (any StreamingMessageState)? {
        streams[id]
    }
}

public protocol StreamingMessageState: AnyObject, Identifiable {
    var id: String { get set }
    var conversationID: Conversation.ID { get set }

    var content: String { get set }
    var files: [ChatMessageContent.File] { get set }
    /// 当前正在 stream 的 assistant 消息是否带 tool calls。带 = 这一轮是中间步骤
    /// (UI 可以渲染成"工具调用进行中"); 空 = 终态/纯回复。
    var toolCalls: [ToolCall] { get set }
    var isFinished: Bool { get set }

    init(conversationID: Conversation.ID)
}
