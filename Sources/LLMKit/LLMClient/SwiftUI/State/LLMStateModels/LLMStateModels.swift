//
//  LLMStateModels.swift
//  LLMKit
//
//  Created by Chocoford on 11/25/25.
//

import Foundation
import LLMCore

public enum ConversationPhase: String, Codable, Sendable {
    case idle
    case loading
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    
    public enum ConversationTpye: Codable, Equatable, Sendable {
        case normal
        case temporary
        case custom(_ label: String)
        
        public var rawValue: String {
            switch self {
                case .normal:
                    "normal"
                case .temporary:
                    "temporary"
                case .custom(let label):
                    label
            }
        }
        
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
        
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            
            if value == "normal" {
                self = .normal
            } else if value == "temporary" {
                self = .temporary
            } else {
                self = .custom(value)
            }
        }
    }
    
    public var type: ConversationTpye
    public var agentConfig: AgentConfig  // Agent configuration
    public var title: String
    public var messages: [ChatMessage] = []
    public var phase: ConversationPhase = .idle

    public var createdAt: Date
    public var lastChatAt: Date

    public init(
        id: String = UUID().uuidString,
        type: ConversationTpye,
        agentConfig: AgentConfig = .chat,
        title: String,
        messages: [ChatMessage] = [],
        createdAt: Date,
        lastChatAt: Date
    ) {
        self.id = id
        self.type = type
        self.agentConfig = agentConfig
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.lastChatAt = lastChatAt
    }
}
