//
//  WebSearchTool.swift
//  LLMKit
//
//  Created by Chocoford
//

import Foundation
import LLMCore

public struct WebSearchTool: Tool {
    public let name: String
    public let description: String
    public let inputSchema: ToolInputSchema

    private let networking: LLMNetworking

    public init(
        client: LLMClient,
        name: String = "web_search",
        description: String = "Search the web for up-to-date information."
    ) {
        self.name = name
        self.description = description
        self.networking = client.networking
        self.inputSchema = .parameters(ToolParameters(
            properties: [
                "query": ParameterProperty(
                    type: "string",
                    description: "The search query to run"
                )
            ],
            required: ["query"]
        ))
    }

    public func execute(_ input: String, context: (any ChatInvocationContext)?) async throws -> ToolResult {
        let query = try parseQuery(from: input)
        let response: ToolExecutionResponse = try await networking.post(
            "/tools/web-search",
            body: ToolExecutionRequest(arguments: query)
        )
        return .text(response.result)
    }

    private func parseQuery(from input: String) throws -> String {
        guard let data = input.data(using: .utf8) else {
            throw ToolError.invalidInput("Expected JSON input")
        }

        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any],
              let query = dict["query"] as? String,
              !query.isEmpty else {
            throw ToolError.invalidInput("Expected JSON with 'query' field")
        }

        return query
    }
}

private struct ToolExecutionRequest: Codable {
    let arguments: String
}

private struct ToolExecutionResponse: Codable {
    let result: String
    let creditsUsed: Double?
    let costUSD: Double?
}
