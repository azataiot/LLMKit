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

extension LLMStatable {
    func updateCreditsInfo(_ creditsInfo: CreditsInfo) {
        self.creditsInfo = creditsInfo
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
        type: Conversation.ConversationTpye = .normal,
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
            streamState.stepType = nil
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
            let responseStream = try await executor.execute(
                conversationID: conversation.id,
                agentConfig: conversation.agentConfig,
                contextMessages: conversation.messages.contentMessages,
                model: model,
                metadata: metadata,
                invocationContext: invocationContext
            )

            // Consume the stream
            var responseMessage: ChatMessage?
            // 跟踪当前正在 stream 的 assistant 消息 id, 切到下一条 assistant / 收到 tool 结果时
            // 把上一条提交进对话历史。
            var streamingAssistantID: String?
            var committedIDs = Set<String>()

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
                        if let prevID = streamingAssistantID {
                            // streamState 里已经有最后状态, 用它构造一条 committed message
                            let streamState = self.streamingStore.stream(for: conversationID)
                            let committed = ChatMessage.content(ChatMessageContent(
                                id: prevID,
                                role: .assistant,
                                content: streamState.content.isEmpty ? nil : streamState.content,
                                files: streamState.files,
                                toolCalls: streamState.toolCalls.isEmpty ? nil : streamState.toolCalls
                            ))
                            commitMessageIfNeeded(committed)
                            streamingAssistantID = nil
                        }
                        commitMessageIfNeeded(.content(content))

                    case .assistant:
                        // 同 id 累加; 切 id 时提交前一条 streaming
                        if let prev = streamingAssistantID, prev != content.id {
                            let streamState = self.streamingStore.stream(for: conversationID)
                            let committed = ChatMessage.content(ChatMessageContent(
                                id: prev,
                                role: .assistant,
                                content: streamState.content.isEmpty ? nil : streamState.content,
                                files: streamState.files,
                                toolCalls: streamState.toolCalls.isEmpty ? nil : streamState.toolCalls
                            ))
                            commitMessageIfNeeded(committed)
                        }
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
