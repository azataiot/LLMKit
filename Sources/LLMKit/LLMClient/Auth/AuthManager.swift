//
//  AuthManager.swift
//  LLMKit
//
//  Created by Chocoford on 9/12/25.
//

import Foundation
import LLMCore

public actor LLMAuthManager {
    private let provider: LLMAuthProvider

    private(set) var onAuthStateChanged: (Bool) -> Void

    var isAuthenticated: Bool {
        get async {
            await provider.networking.token != nil
        }
    }
    
    public init(provider: LLMAuthProvider, onAuthStateChanged: @escaping (Bool) -> Void) {
        self.provider = provider
        self.onAuthStateChanged = onAuthStateChanged
    }

    public func restore() async {
        do {
            try await restoreThrowing()
        } catch {
            await self.provider.networking.setToken(nil)
            self.onAuthStateChanged(false)
        }
    }

    @available(*, deprecated, message: "Configure subscriptionGroupID in the auth provider and call restore() instead.")
    public func restore(productIDs: [String]) async {
        fatalError("restore(productIDs:) is deprecated. Configure subscriptionGroupID in the auth provider and call restore() instead.")
    }

    @available(*, deprecated, message: "Configure subscriptionGroupID in the auth provider and call restore() instead.")
    public func restore(groupID: String) async {
        fatalError("restore(groupID:) is deprecated. Configure subscriptionGroupID in the auth provider and call restore() instead.")
    }

    public func restoreThrowing() async throws {
        do {
            let token = try await provider.restoreAuth()
            await self.provider.networking.setToken(token)
            self.onAuthStateChanged(true)
        } catch {
            await self.provider.networking.setToken(nil)
            self.onAuthStateChanged(false)
            throw error
        }
    }

    /// Return the current balance after purchase
    public func purchaseCompleted(jws: String) async throws -> CreditsInfo {
        let response = try await provider.handlePurchase(transactionJWS: jws)
        // self.token = response.token
        return response
    }

    public func subscriptionPurchaseCompleted(jws: String) async throws {
        do {
            let token = try await provider.handleSubscriptionPurchase(transactionJWS: jws)
            await self.provider.networking.setToken(token)
            self.onAuthStateChanged(true)
        } catch {
            await self.provider.networking.setToken(nil)
            self.onAuthStateChanged(false)
            throw error
        }
    }
}
