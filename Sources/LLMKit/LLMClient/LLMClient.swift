//
//  LLMClient.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

import Foundation
@preconcurrency import Combine
import Logging
import LLMCore

public final class LLMClient: Sendable {
    private let authManager: LLMAuthManager
    internal let networking: LLMNetworking
    internal let uploader: (any LLMFileUploadProvider)?
    internal let uploadPolicy: LLMUploadPolicy?
    
    private let logger = Logger(label: "LLMClient")
    
    public init(
        authProvider: LLMAuthProvider,
        uploadProvider: (any LLMFileUploadProvider)? = nil,
        uploadPolicy: LLMUploadPolicy? = nil
    ) {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: authProvider) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = uploadProvider
        self.uploadPolicy = uploadPolicy
    }
    
    public init(
        authProvider: any LLMAuthProviderBuilder,
        uploadProvider: (any LLMFileUploadProviderBuilder)? = nil,
        uploadPolicy: LLMUploadPolicy? = nil
    ) {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: authProvider(self.networking)) { isAuthenticated in
            DispatchQueue.main.async {
                authStateChangedPublisher.send(isAuthenticated)
            }
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = uploadProvider?(self.networking)
        self.uploadPolicy = uploadPolicy
    }
    
    init() {
        self.networking = LLMNetworking()
        let authStateChangedPublisher = PassthroughSubject<Bool, Never>()
        self.authManager = LLMAuthManager(provider: NoAuthProvider()) {
            authStateChangedPublisher.send($0)
        }
        self.authStateChangedPublisher = authStateChangedPublisher
        self.uploader = nil
        self.uploadPolicy = nil
    }
    
    internal let authStateChangedPublisher: PassthroughSubject<Bool, Never>
    
    // 应用启动时调用
    public func restore(productIDs: [String]) async {
        await authManager.restore(productIDs: productIDs)
        
        if await authManager.isAuthenticated {
            do {
                _ = try await self.getCredits()
            } catch {
                logger.error("Failed to fetch credits after restore: \(error)")
            }
        }
    }
    
    public func restore(groupID: String) async {
        await authManager.restore(groupID: groupID)
        
        if await authManager.isAuthenticated {
            do {
                _ = try await self.getCredits()
            } catch {
                logger.error("Failed to fetch credits after restore: \(error)")
            }
        }
    }
    
    internal let creditsUpdatePublisher = PassthroughSubject<CreditsInfo, Never>()
    
    // MARK: - Private Request Helper
    
    private func withUsageMiddleware<T: Codable>(_ response: APIResponse<T>) -> APIResponse<T> {
        if let remainsCredit = response.credits?.remains {
            // Create a minimal CreditsInfo with only balance
            let creditsInfo = CreditsInfo(
                balance: remainsCredit,
                subscription: nil,
                purchasedCredits: 0
            )
            DispatchQueue.main.async {
                self.creditsUpdatePublisher.send(creditsInfo)
            }
        }

        return response
    }
    
    public func ask(
        prompt: String,
        model: SupportedModel = .gpt4oMini
    ) async throws -> APIResponse<ChatMessageContent> {
        let body = AskRequest<EmptyMetadata>(prompt: prompt, model: model)
        let response: APIResponse<ChatMessageContent> = try await self.networking.post("/chat/ask", body: body)

        return withUsageMiddleware(response)
    }
    
    // MARK: - Credits
    /// Get credits information including balance, subscription and purchased credits
    @discardableResult
    public func getCredits() async throws -> CreditsInfo {
        let response: CreditsInfo = try await self.networking.get("/credits")
        // 更新全局状态
        DispatchQueue.main.async {
            self.creditsUpdatePublisher.send(response)
        }
        return response
    }
    
    /// Get transaction history with pagination
    /// - Parameters:
    ///   - page: Page number (default: 1)
    ///   - pageSize: Number of transactions per page (default: 20)
    ///   - type: Optional filter by transaction type
    public func getTransactionHistory(
        page: Int = 1,
        pageSize: Int = 20,
        type: CreditsTransactionType? = nil
    ) async throws -> TransactionHistory {
        var queryParams: [String: String] = [
            "page": String(page),
            "pageSize": String(pageSize)
        ]
        if let type = type {
            queryParams["type"] = type.rawValue
        }

        let queryString = queryParams
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")

        let response: TransactionHistory = try await self.networking.get("/credits/transactions?\(queryString)")
        return response
    }
    
    @discardableResult
    public func addCredits(transactionSignedData: String) async throws -> CreditsInfo {
        let creditsInfo = try await self.authManager.purchaseCompleted(jws: transactionSignedData)

        // 更新全局状态
        DispatchQueue.main.async {
            self.creditsUpdatePublisher.send(creditsInfo)
        }
        return creditsInfo
    }
}
