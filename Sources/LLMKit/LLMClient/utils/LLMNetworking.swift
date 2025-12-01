//
//  LLMNetworking.swift
//  LLMKit
//
//  Created by Chocoford on 9/12/25.
//

import Foundation
import LLMCore
import Logging

private struct EmptyBody: Encodable {}

public actor LLMNetworking {
    private let id = UUID()
    private let baseURL: URL
    private let session: URLSession
    private(set) var token: String?
    
    private let logger = Logger(label: "LLMNetworking")
    
    public init(
        session: URLSession = .shared
    ) {
//#if DEBUG
        self.baseURL = URL(string: "http://127.0.0.1:8080")!
//#else
//        self.baseURL = URL(string: "https://llm.chocoford.com")!
//#endif
        self.session = session
    }
    
    let jsonDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // 设置 / 更新 token（由 AuthManager 调用）
    public func setToken(_ token: String?) {
        self.token = token
    }

    // GET 请求
    public func get<T: Decodable>(
        _ endpoint: String
    ) async throws -> T {
        let body: EmptyBody? = nil
        let request = try makeRequest(endpoint: endpoint, method: "GET", body: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decode(T.self, from: data)
    }

    // POST 请求
    public func post<T: Encodable, U: Decodable>(
        _ endpoint: String,
        body: T,
    ) async throws -> U {
        let request = try makeRequest(endpoint: endpoint, method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decode(U.self, from: data)
    }
    
    // MARK: - 新增: 流式请求
    public func stream<T: Encodable>(
        _ endpoint: String,
        body: T
    ) throws -> AsyncThrowingStream<StreamChatResponse, Error> {
        let request = try makeRequest(endpoint: endpoint, method: "POST", body: body)
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    
                    for try await line in bytes.lines {
                        // print("Received line: \(line)")
                        if line.hasPrefix("data: ") {
                            let jsonPart = String(line.dropFirst(6))
                            if jsonPart == "[DONE]" {
                                continuation.finish()
                                break
                            }
                            
                            // 尝试解码成目标类型
                            if !jsonPart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                let data = jsonPart.data(using: .utf8) {
                                do {
                                    let decoded = try JSONDecoder().decode(StreamChatResponse.self, from: data)
                                    continuation.yield(decoded)
                                } catch {
                                    print(error)
                                    continue
                                }
                            }
                        } else {
                            
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers
    private func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        do {
            return try jsonDecoder.decode(type, from: data)
        } catch {
            // 记录原始 JSON 以便调试
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.error("Failed to decode \(String(describing: type)). Raw JSON: \(jsonString)")
            } else {
                logger.error("Failed to decode \(String(describing: type)). Could not convert data to string.")
            }
            throw error
        }
    }

    
    private func makeRequest<T: Encodable>(
        endpoint: String,
        method: String,
        body: T? = nil,
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // print("[LLMNetworking<\(id)>] makeRequest to:", url.absoluteString, "token: ", token)
        if let token {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            // 尝试解码错误响应
            do {
                let errorResponse = try JSONDecoder().decode(ErrorResponse.self, from: data)
                throw NSError(
                    domain: "LLMNetworking",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: errorResponse.error.message]
                )
            } catch is DecodingError {
                // 如果无法解码为标准错误格式，抛出通用错误
                throw NSError(
                    domain: "LLMNetworking",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            }
        }
    }
}

// MARK: - Error Response Model
private struct ErrorResponse: Codable {
    let error: APIError
}
