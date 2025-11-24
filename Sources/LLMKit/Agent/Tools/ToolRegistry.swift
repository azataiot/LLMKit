//
//  ToolRegistry.swift
//  LLMKit
//
//  Created by Claude Code
//

import Foundation

/// Registry for managing available tools
public actor ToolRegistry {
    private var tools: [String: Tool] = [:]

    public init() {}

    /// Register a tool
    public func register(_ tool: Tool) {
        tools[tool.name] = tool
    }

    /// Register multiple tools
    public func register(_ tools: [Tool]) {
        for tool in tools {
            register(tool)
        }
    }

    /// Get a tool by name
    public func get(_ name: String) -> Tool? {
        return tools[name]
    }

    /// Get multiple tools by names
    public func get(_ names: [String]) -> [Tool] {
        return names.compactMap { tools[$0] }
    }

    /// Get all registered tools
    public func all() -> [Tool] {
        return Array(tools.values)
    }

    /// Remove a tool
    public func remove(_ name: String) {
        tools.removeValue(forKey: name)
    }

    /// Clear all tools
    public func clear() {
        tools.removeAll()
    }

    /// Generate tools description for system prompt
    /// - Parameter toolNames: Names of tools to include in the description
    /// - Returns: Formatted string describing the tools
    public func generateToolsDescription(for toolNames: [String]) -> String {
        let selectedTools = get(toolNames)
        guard !selectedTools.isEmpty else {
            return ""
        }

        let toolsDesc = selectedTools.map { tool in
            """
            - \(tool.name): \(tool.description)
              Parameters: \(tool.parameters.properties.keys.joined(separator: ", "))
            """
        }.joined(separator: "\n")

        return """
        You have access to the following tools:

        \(toolsDesc)

        To use a tool, respond with:
        Action: <tool_name>
        Input: <json_input>
        """
    }
}
