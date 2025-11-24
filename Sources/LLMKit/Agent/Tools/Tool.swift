//
//  Tool.swift
//  LLMKit
//
//  Created by Claude Code
//

import Foundation

/// Protocol for tools that agents can use
public protocol Tool: Sendable {
    /// Unique name of the tool
    var name: String { get }

    /// Description of what the tool does
    var description: String { get }

    /// JSON schema describing the tool's parameters
    var parameters: ToolParameters { get }

    /// Execute the tool with given input
    /// - Parameter input: JSON string containing the tool input
    /// - Returns: Tool execution result as string
    func execute(_ input: String) async throws -> String
}

/// Tool parameter schema
public struct ToolParameters: Codable, Sendable {
    public var type: String
    public var properties: [String: ParameterProperty]
    public var required: [String]

    public init(
        type: String = "object",
        properties: [String: ParameterProperty],
        required: [String] = []
    ) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

/// Individual parameter property
public struct ParameterProperty: Codable, Sendable {
    public var type: String
    public var description: String
    public var `enum`: [String]?

    public init(type: String, description: String, enum: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = `enum`
    }
}

/// Tool execution error
public enum ToolError: Error {
    case invalidInput(String)
    case executionFailed(String)
    case toolNotFound(String)
}
