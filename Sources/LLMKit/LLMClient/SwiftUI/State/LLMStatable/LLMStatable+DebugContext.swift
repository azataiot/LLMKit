//
//  LLMStatable+DebugContext.swift
//  LLMKit
//

#if DEBUG
import Foundation
import LLMCore

/// Controls how local/base64 files are represented in debug context snapshots.
public enum DebugChatContextFilePreparationMode: String, Codable, Sendable {
    /// Return the active context exactly as it exists in memory after appending the pending user message.
    /// This has no upload side effects, but local `file://` URLs may still be present.
    case activeContextOnly

    /// Run the same file preparation used by the real send path before returning the context.
    /// If an uploader is configured, this can upload files as a side effect.
    case preparedForSend
}

/// Debug-only view of the context that LLMKit would pass into AgentExecutor for one send.
public struct DebugChatContextSnapshot: Codable, Equatable, Sendable {
    public let conversationID: String
    public let model: SupportedModel
    public let stream: Bool
    public let agentConfig: AgentConfig
    public let filePreparationMode: DebugChatContextFilePreparationMode
    public let contextMessages: [ChatMessageContent]

    public init(
        conversationID: String,
        model: SupportedModel,
        stream: Bool,
        agentConfig: AgentConfig,
        filePreparationMode: DebugChatContextFilePreparationMode,
        contextMessages: [ChatMessageContent]
    ) {
        self.conversationID = conversationID
        self.model = model
        self.stream = stream
        self.agentConfig = agentConfig
        self.filePreparationMode = filePreparationMode
        self.contextMessages = contextMessages
    }
}

extension LLMStatable {
    func _debugChatContext(
        to conversationID: String,
        model: SupportedModel,
        message: ChatMessage,
        stream: Bool,
        filePreparationMode: DebugChatContextFilePreparationMode
    ) async throws -> DebugChatContextSnapshot {
        guard case .loaded = conversations else {
            throw ConversationNotReadyError()
        }

        guard let index = self.conversations.value?.firstIndex(where: { $0.id == conversationID }) else {
            throw ConversationNotFoundError()
        }

        var conversation = self.conversations.value![index]
        conversation.messages.append(message)

        if filePreparationMode == .preparedForSend {
            conversation = try await llmClient.prepareUploadFilesForActiveContext(for: conversation)
        }

        return DebugChatContextSnapshot(
            conversationID: conversationID,
            model: model,
            stream: stream,
            agentConfig: conversation.agentConfig,
            filePreparationMode: filePreparationMode,
            contextMessages: conversation.messages.contextMessages
        )
    }
}
#endif
