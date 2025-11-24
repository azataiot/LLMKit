//
//  AgentConfig.swift
//  LLMKit
//
//  Created by Claude Code
//

import Foundation

/// Types of steps an agent can perform
public enum AgentStepType: String, Codable, Sendable, Hashable {
    case thought      // 思考、推理
    case plan         // 规划步骤
    case action       // 使用工具（执行后自动产生observation）
    case reflection   // 自我反思

    /// Whether this step type automatically produces an observation
    public var needsObservation: Bool {
        switch self {
        case .action:
            return true
        case .thought, .plan, .reflection:
            return false
        }
    }

    /// Instruction for this step type
    public var instruction: String {
        switch self {
            case .thought:
                return """
                Think step by step about what you need to do next.

                IMPORTANT: Your thought should ONLY contain your reasoning process.
                DO NOT output any action keywords (Action:, Plan:, Reflection:, Final Answer:) in your thought.
                After your thought is complete, THEN output the action format on a new line.
                """
            case .action:
                return """
                When you need to use a tool, respond with:
                Action: <tool_name>
                Input: <json_input>

                After the action executes, you will receive an observation with the result.
                """
            case .plan:
                return """
                When you need to create a plan, respond with:
                Plan: <your_plan>
                """
            case .reflection:
                return """
                When you need to reflect on your actions, respond with:
                Reflection: <your_reflection>
                """
        }
    }
}

extension Array where Element == AgentStepType {
    /// Generate prompt instructions from step types
    /// - Returns: Combined instruction text, with thought always first
    public func generatePrompt() -> String {
        guard !isEmpty else {
            return ""
        }

        // Thought must always be first if present
        guard contains(.thought) else {
            return ""
        }

        // Build ordered steps: thought first, then others in defined order
        var orderedSteps: [AgentStepType] = [.thought]

        // Add other steps in preferred order: plan -> action -> reflection
        let otherStepsOrder: [AgentStepType] = [.plan, .action, .reflection]
        for stepType in otherStepsOrder {
            if contains(stepType) {
                orderedSteps.append(stepType)
            }
        }

        // Generate instructions
        var instructions = orderedSteps.map { $0.instruction }.joined(separator: "\n\n")

        // Always append final answer instruction (every agent must be able to answer)
        if !instructions.isEmpty {
            instructions += "\n\n"
        }
        instructions += """
        IMPORTANT - Final Answer Format:
        When you have enough information to answer the user's question, you MUST respond with:
        Final Answer: <your_answer>

        This is the ONLY way to complete the task. Do not just provide an answer without this format.

        CRITICAL: You MUST use the EXACT English keywords shown above (Action:, Input:, Plan:, Reflection:, Final Answer:).
        DO NOT translate these keywords to any other language. The system parser only recognizes these English keywords.
        """

        return instructions
    }
}

/// Configuration for agent behavior
public struct AgentConfig: Codable, Sendable, Equatable {
    /// Allowed step types for this agent
    /// Empty set means direct response (traditional chat)
    public var allowedSteps: Set<AgentStepType>
    
    /// Available tools for the agent
    public var tools: [String]

    /// System message for the agent
    public var systemMessage: String?

    /// Maximum number of thought steps allowed
    public var maxThoughts: Int

    /// Temperature for LLM sampling
    public var temperature: Double

    public init(
        allowedSteps: Set<AgentStepType> = [],
        tools: [String] = [],
        systemMessage: String? = nil,
        maxThoughts: Int = 10,
        temperature: Double = 0.7
    ) {
        self.allowedSteps = allowedSteps
        self.tools = tools
        self.systemMessage = systemMessage
        self.maxThoughts = maxThoughts
        self.temperature = temperature
    }
    
    /// Traditional chat configuration (no steps, direct response)
    public static var chat: AgentConfig {
        AgentConfig(allowedSteps: [])
    }
    
    /// ReAct agent configuration (thought → action with automatic observation)
    public static func react(tools: [String], maxThoughts: Int = 10) -> AgentConfig {
        AgentConfig(
            allowedSteps: [.thought, .action],
            tools: tools,
            maxThoughts: maxThoughts
        )
    }

    /// Plan-and-Execute agent configuration
    public static func planAndExecute(tools: [String], maxThoughts: Int = 10) -> AgentConfig {
        AgentConfig(
            allowedSteps: [.plan, .thought, .action],
            tools: tools,
            maxThoughts: maxThoughts
        )
    }

    /// Reflexion agent configuration (with self-reflection)
    public static func reflexion(tools: [String], maxThoughts: Int = 10) -> AgentConfig {
        AgentConfig(
            allowedSteps: [.thought, .action, .reflection],
            tools: tools,
            maxThoughts: maxThoughts
        )
    }
    
    /// Generate strategy instructions based on allowed steps
    /// - Returns: Combined instruction text from all allowed steps
    public func generateStrategyInstructions() -> String {
        return Array(allowedSteps).generatePrompt()
    }
}
