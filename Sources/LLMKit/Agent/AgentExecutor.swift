//
//  AgentExecutor.swift
//  LLMKit
//
//  Created by Claude Code
//

import Foundation
import LLMCore
import Logging

/// Agent execution errors
public enum AgentError: Error, LocalizedError {
    case maxThoughtsReached
    case toolNotFound(String)
    case toolExecutionFailed(String)
    case invalidToolCall(String)
    case conversationNotFound
    
    public var errorDescription: String? {
        switch self {
            case .maxThoughtsReached:
                return "Agent reached maximum thought steps without finding an answer"
            case .toolNotFound(let name):
                return "Tool not found: \(name)"
            case .toolExecutionFailed(let reason):
                return "Tool execution failed: \(reason)"
            case .invalidToolCall(let reason):
                return "Invalid tool call: \(reason)"
            case .conversationNotFound:
                return "Conversation not found"
        }
    }
}

/// Parsed response from thought step
private enum ThoughtResponse {
    case finalAnswer(String)
    case nextStep(AgentStepType, StepContent)
    case unknown(String)  // Continue without specific action
}

/// Content of a step
private enum StepContent {
    case toolCall(ToolCall)
    case text(String)
}

/// Agent executor that handles execution based on configuration
@MainActor
public class AgentExecutor {
    private let logger = Logger(label: "AgentExecutor")
    private let llmClient: LLMClient
    private let toolRegistry: ToolRegistry
    
    public init(llmClient: LLMClient, toolRegistry: ToolRegistry) {
        self.llmClient = llmClient
        self.toolRegistry = toolRegistry
    }
    
    /// Execute agent based on conversation configuration
    public func execute(
        conversation: Conversation,
        userMessage: ChatMessage,
        model: SupportedModel,
        stream: Bool = true,
        onStep: @escaping (AgentStep) async -> Void
    ) async throws -> ChatMessage {
        let config = conversation.agentConfig
        let tools = await toolRegistry.get(config.tools)
        let canStream = model.supportsStreaming

        logger.info("""
                    ==== Executing agent ====
                    - conversationID: \(conversation.id)
                    - steps: \(config.allowedSteps)
                    - tools: \(config.tools) (\(tools.count) loaded)
                    - maxThoughts: \(config.maxThoughts)
                    - stream: \(stream && canStream)
                    ==== Executing agent end ====
                    """)

        var context = conversation.messages.contentMessages
        logger.info("Context messages count: \(context.count)")
        for (index, msg) in context.enumerated() {
            logger.info("  [\(index)] role: \(msg.role), content: \(msg.content?.prefix(50) ?? "nil")...")
        }

        var thoughtCount = 0
        var accumulatedFiles: [ChatMessageContent.File] = []  // Track files from streaming responses

        // Main thought loop - every iteration starts with a thought
        while thoughtCount < config.maxThoughts {
            thoughtCount += 1
            logger.debug("Thought \(thoughtCount)/\(config.maxThoughts)")

            // Step 1: Get thought response from LLM
            let thoughtMessage = try await requestThought(
                model: model,
                context: context,
                stream: stream && canStream,
                thoughtNumber: thoughtCount,
                config: config,
                onStep: onStep
            )

            // Accumulate files from this thought
            if let files = thoughtMessage.files {
                accumulatedFiles.append(contentsOf: files)
            }

            let thoughtContent = thoughtMessage.content ?? ""

            // Step 2: Parse the thought response
            logger.debug("Thought content (first 200 chars): \(thoughtContent.prefix(200))")
            let response = parseThoughtResponse(thoughtContent, config: config)

            // Step 3: Handle the response with switch
            switch response {
                case .finalAnswer(let answer):
                    // Found final answer - return directly
                    logger.info("Agent completed with final answer after \(thoughtCount) thought(s)")
                    return .content(ChatMessageContent(
                        role: .assistant,
                        content: answer,
                        files: accumulatedFiles
                    ))
                    
                case .nextStep(let stepType, let stepContent):
                    // Execute the next step based on type
                    logger.debug("Next step: \(stepType)")
                    // Handle step execution based on type
                    switch stepType {
                        case .action:
                            // Action requires tool execution
                            guard case .toolCall(let toolCall) = stepContent else {
                                throw AgentError.invalidToolCall("Invalid action content")
                            }
                            
                            // Emit action step
                            let actionStep = AgentStep(
                                stepNumber: thoughtCount,
                                type: .action,
                                content: "Action: \(toolCall.tool)\nInput: \(toolCall.input)"
                            )
                            await onStep(actionStep)
                            
                            // Execute tool
                            guard let tool = tools.first(where: { $0.name == toolCall.tool }) else {
                                throw AgentError.toolNotFound(toolCall.tool)
                            }
                            
                            do {
                                let observation = try await tool.execute(toolCall.input)
                                logger.debug("Tool execution result: \(observation.prefix(100))...")
                                
                                // Emit observation (action needs observation)
                                await emitObservation(
                                    stepNumber: thoughtCount,
                                    content: "Observation: \(observation)",
                                    onStep: onStep
                                )
                                
                                // Add thought and observation to context
                                context.append(ChatMessageContent(role: .assistant, content: thoughtContent))
                                context.append(ChatMessageContent(role: .system, content: "Observation: \(observation)"))
                                
                            } catch {
                                let errorMsg = "Tool execution failed: \(error.localizedDescription)"
                                logger.error("\(errorMsg)")
                                
                                // Emit error observation
                                await emitObservation(
                                    stepNumber: thoughtCount,
                                    content: "Error: \(errorMsg)",
                                    onStep: onStep
                                )
                                
                                context.append(ChatMessageContent(role: .assistant, content: thoughtContent))
                                // Add error to context
                                context.append(ChatMessageContent(role: .system, content: errorMsg))
                            }
                            
                        case .plan, .reflection:
                            // Simple steps that don't need async execution
                            guard case .text(let textContent) = stepContent else {
                                throw AgentError.invalidToolCall("Invalid \(stepType) content")
                            }
                            
                            // Emit step
                            let step = AgentStep(
                                stepNumber: thoughtCount,
                                type: stepType == .plan ? .plan : .reflection,
                                content: textContent
                            )
                            await onStep(step)
                            
                            // Add thought and step to context
                            context.append(ChatMessageContent(role: .assistant, content: thoughtContent))
                            
                            let stepPrefix = stepType == .plan ? "Plan:" : "Reflection:"
                            context.append(ChatMessageContent(
                                role: .assistant,
                                content: "\(stepPrefix) \(textContent)"
                            ))
                            
                        case .thought:
                            // Thought should not appear as nextStep
                            throw AgentError.invalidToolCall("Thought cannot be a next step")
                    }
                    // Continue to next thought
                    continue
                    
                case .unknown(let content):
                    // No specific action detected - return as final answer
                    logger.info("No specific action detected after \(thoughtCount) thought(s), treating as final answer")
                    logger.debug("Content: \(content.prefix(200))")
                    return .content(ChatMessageContent(
                        role: .assistant,
                        content: content,
                        files: accumulatedFiles
                    ))
            }
        }
        
        throw AgentError.maxThoughtsReached
    }
    
    /// Request a thought step from LLM
    private func requestThought(
        model: SupportedModel,
        context: [ChatMessageContent],
        stream: Bool,
        thoughtNumber: Int,
        config: AgentConfig,
        onStep: @escaping (AgentStep) async -> Void
    ) async throws -> ChatMessageContent {
        if stream {
            // Streaming mode
            let stream = try await llmClient.streamChat(
                model: model,
                messages: context
            )

            var accumulatedMessage: ChatMessageContent?
            var streamStepId: UUID? = nil

            for try await result in stream {
                switch result {
                    case .message(let chunk):
                        if let existing = accumulatedMessage {
                            // Accumulate content and files
                            let newContent = (existing.content ?? "") + (chunk.content ?? "")
                            let newFiles = (existing.files ?? []) + (chunk.files ?? [])
                            accumulatedMessage = ChatMessageContent(
                                id: existing.id,
                                role: existing.role,
                                content: newContent,
                                files: newFiles
                            )
                        } else {
                            // First chunk
                            accumulatedMessage = chunk
                        }

                        // Emit/update thought step in real-time
                        if config.allowedSteps.contains(.thought), let content = accumulatedMessage?.content {
                            // Truncate thought content at first action keyword to avoid duplication
                            let thoughtContent = truncateAtActionKeyword(content)

                            let thoughtStep = AgentStep(
                                id: streamStepId ?? UUID(),
                                stepNumber: thoughtNumber,
                                type: .thought,
                                content: thoughtContent
                            )
                            if streamStepId == nil {
                                streamStepId = thoughtStep.id
                            }
                            await onStep(thoughtStep)
                        }

                    case .settlement(_):
                        break
                }
            }

            guard let message = accumulatedMessage, let content = message.content, !content.isEmpty else {
                throw AgentError.toolExecutionFailed("No response from LLM")
            }

            return message
        } else {
            // Non-streaming mode
            let result = try await llmClient.chat(
                model: model,
                messages: context
            )

            guard let message = result.data else {
                if let error = result.error {
                    throw AgentError.toolExecutionFailed(error.message)
                }
                throw AgentError.toolExecutionFailed("No response from LLM")
            }

            guard let content = message.content, !content.isEmpty else {
                throw AgentError.toolExecutionFailed("Empty response from LLM")
            }

            // Emit thought step
            if config.allowedSteps.contains(.thought) {
                let thoughtStep = AgentStep(
                    stepNumber: thoughtNumber,
                    type: .thought,
                    content: content
                )
                await onStep(thoughtStep)
            }

            return message
        }
    }
    
    /// Helper to emit observation step
    private func emitObservation(
        stepNumber: Int,
        content: String,
        onStep: (AgentStep) async -> Void
    ) async {
        let observationStep = AgentStep(
            stepNumber: stepNumber,
            type: .observation,
            content: content
        )
        await onStep(observationStep)
    }

    /// Truncate content at first action keyword to prevent duplication in streaming
    private func truncateAtActionKeyword(_ text: String) -> String {
        let keywords = ["Action:", "Plan:", "Reflection:", "Final Answer:"]

        var earliestRange: Range<String.Index>? = nil

        for keyword in keywords {
            if let range = text.range(of: keyword) {
                if earliestRange == nil || range.lowerBound < earliestRange!.lowerBound {
                    earliestRange = range
                }
            }
        }

        guard let range = earliestRange else {
            return text
        }

        // Return content before the keyword, trimmed
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Parse thought response to determine next action
    private func parseThoughtResponse(_ text: String, config: AgentConfig) -> ThoughtResponse {
        // Priority 1: Check for final answer (always check, as every agent must return answer)
        if let finalAnswer = parseFinalAnswer(from: text) {
            return .finalAnswer(finalAnswer)
        }
        
        // Priority 2: Check for each allowed step type
        if config.allowedSteps.contains(.action), let toolCall = parseToolCall(from: text) {
            return .nextStep(.action, .toolCall(toolCall))
        }
        
        if config.allowedSteps.contains(.plan), let plan = parsePlan(from: text) {
            return .nextStep(.plan, .text(plan))
        }
        
        if config.allowedSteps.contains(.reflection), let reflection = parseReflection(from: text) {
            return .nextStep(.reflection, .text(reflection))
        }
        
        // Priority 3: Unknown - no specific action detected
        return .unknown(text)
    }
    
    /// Parse tool call from LLM response
    private func parseToolCall(from text: String) -> ToolCall? {
        let lines = text.components(separatedBy: "\n")
        
        var action: String?
        var input: String?
        
        for line in lines {
            if line.hasPrefix("Action:") {
                action = line.replacingOccurrences(of: "Action:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Input:") {
                input = line.replacingOccurrences(of: "Input:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        
        guard let action = action, let input = input else {
            return nil
        }
        
        return ToolCall(tool: action, input: input)
    }
    
    /// Parse final answer from LLM response
    private func parseFinalAnswer(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("Final Answer:") {
                let answer = line.replacingOccurrences(of: "Final Answer:", with: "").trimmingCharacters(in: .whitespaces)
                
                if !answer.isEmpty {
                    let remainingLines = lines[(index + 1)...].joined(separator: "\n")
                    if !remainingLines.isEmpty {
                        return answer + "\n" + remainingLines
                    }
                    return answer
                }
                
                let remainingLines = lines[(index + 1)...].joined(separator: "\n")
                return remainingLines.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
    
    /// Parse plan from LLM response
    private func parsePlan(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("Plan:") {
                let plan = line.replacingOccurrences(of: "Plan:", with: "").trimmingCharacters(in: .whitespaces)
                
                if !plan.isEmpty {
                    let remainingLines = lines[(index + 1)...].joined(separator: "\n")
                    if !remainingLines.isEmpty {
                        return plan + "\n" + remainingLines
                    }
                    return plan
                }
                
                let remainingLines = lines[(index + 1)...].joined(separator: "\n")
                return remainingLines.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
    
    /// Parse reflection from LLM response
    private func parseReflection(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("Reflection:") {
                let reflection = line.replacingOccurrences(of: "Reflection:", with: "").trimmingCharacters(in: .whitespaces)
                
                if !reflection.isEmpty {
                    let remainingLines = lines[(index + 1)...].joined(separator: "\n")
                    if !remainingLines.isEmpty {
                        return reflection + "\n" + remainingLines
                    }
                    return reflection
                }
                
                let remainingLines = lines[(index + 1)...].joined(separator: "\n")
                return remainingLines.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
}
