//
//  AuthProvider.swift
//  LLMKit
//
//  Created by Chocoford on 9/12/25.
//

import Foundation
import LLMCore

public protocol LLMAuthProvider: Sendable {
    var networking: LLMNetworking { get }
    
    /// Restore / refresh the auth identity for this provider.
    ///
    /// Provider-specific configuration should be captured by the provider itself. For example,
    /// App Store subscription restore uses the provider's configured subscription group instead of
    /// accepting a group ID at the call site.
    func restoreAuth() async throws -> String

    /// Handle a verified subscription transaction JWS and return the auth token.
    ///
    /// This is intended for explicit StoreKit purchase completion. Providers that do not have
    /// a separate subscription path may fall back to `restoreAuth()`.
    func handleSubscriptionPurchase(transactionJWS: String) async throws -> String

    /// Handle a verified non-subscription purchase JWS and return the updated credits snapshot.
    func handlePurchase(transactionJWS: String) async throws -> CreditsInfo
}

public protocol LLMAuthProviderBuilder: Sendable {
    func callAsFunction(_ networking: LLMNetworking) -> any LLMAuthProvider
}

public extension LLMAuthProvider {
    func handleSubscriptionPurchase(transactionJWS: String) async throws -> String {
        try await restoreAuth()
    }

    @available(*, deprecated, message: "Configure subscriptionGroupID in the auth provider and call restoreAuth() instead.")
    func restoreAuth(productIDs: [String]) async throws -> String {
        fatalError("restoreAuth(productIDs:) is deprecated. Configure subscriptionGroupID in the auth provider and call restoreAuth() instead.")
    }

    @available(*, deprecated, message: "Configure subscriptionGroupID in the auth provider and call restoreAuth() instead.")
    func restoreAuth(groupID: String) async throws -> String {
        fatalError("restoreAuth(groupID:) is deprecated. Configure subscriptionGroupID in the auth provider and call restoreAuth() instead.")
    }
}

struct NoAuthProvider: LLMAuthProvider {
    let networking: LLMNetworking = .init()

    func restoreAuth() async throws -> String {
        ""
    }

    func handleSubscriptionPurchase(transactionJWS: String) async throws -> String {
        ""
    }
    
    func handlePurchase(transactionJWS: String) async throws -> CreditsInfo {
        return .init(balance: 0, purchasedCredits: 0)
    }
}
