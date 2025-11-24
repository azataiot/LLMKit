//
//  ChatMessage.swift
//  LLMKit
//
//  Created by Claude Code
//

import Foundation
import LLMCore

/// Client-side message representation with UI states
public enum ChatMessage: Codable, Equatable, Identifiable, Sendable {
    case loading(UUID = UUID())
    case content(ChatMessageContent)
    case error(UUID, String)
    case agentStep(AgentStep)  // Agent execution step

    public var id: String {
        switch self {
            case .loading(let id):
                return id.uuidString
            case .content(let content):
                return content.id
            case .error(let id, _):
                return id.uuidString
            case .agentStep(let step):
                return step.id.uuidString
        }
    }

    public var role: ChatMessageContent.Role? {
        switch self {
            case .loading:
                nil
            case .content(let chatMessageContent):
                chatMessageContent.role
            case .error:
                nil
            case .agentStep:
                .assistant  // Agent steps are assistant's behavior
        }
    }

    public var content: String? {
        get {
            switch self {
                case .content(let content):
                    content.content
                case .error(_, let errorMessage):
                    errorMessage
                case .agentStep(let step):
                    step.content
                default:
                    nil
            }
        }
        set {
            switch self {
                case .content(var content):
                    content.content = newValue
                    self = .content(content)
                default:
                    return
            }
        }
    }

    public var files: [ChatMessageContent.File]? {
        get {
            if case .content(let content) = self {
                return content.files
            }
            return nil
        }

        set {
            switch self {
                case .content(var content):
                    content.files = newValue
                    self = .content(content)
                default:
                    return
            }
        }
    }

    public var usage: CreditsResult? {
        get {
            switch self {
                case .content(let content):
                    content.usage
                default:
                    nil
            }
        }
        set {
            switch self {
                case .content(var content):
                    content.usage = newValue
                    self = .content(content)
                default:
                    return
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        // Try decoding as AgentStep first
        if let step = try? AgentStep(from: decoder) {
            self = .agentStep(step)
            return
        }

        // Fall back to ChatMessageContent for backward compatibility
        self = .content(try ChatMessageContent(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
            case .content(let content):
                try content.encode(to: encoder)
            case .agentStep(let step):
                try step.encode(to: encoder)
            default:
                // loading and error are not persisted
                return
        }
    }
}

extension [ChatMessage] {
    public var contentMessages: [ChatMessageContent] {
        get {
            self.compactMap {
                switch $0 {
                    case .content(let content):
                        content
                    default:
                        nil
                }
            }
        }
        set {
            var j = newValue.startIndex
            for i in self.indices {
                if j >= newValue.endIndex {
                    break
                }
                if case .content = self[i] {
                    self[i] = .content(newValue[j])
                    j += 1
                }
            }
        }
    }
}
