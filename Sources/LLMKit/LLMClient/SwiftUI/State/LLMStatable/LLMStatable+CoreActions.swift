//
//  LLMStatable+CoreActions.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

extension LLMStatable {
    func _handlePurchase(verificationResult: VerificationResult<Transaction>) async throws {
        switch verificationResult {
            case .verified(let signed):
                if signed.subscriptionGroupID != nil {
                    // subscription
                    _ = try await self.llmClient.completeSubscriptionPurchase(
                        transactionSignedData: verificationResult.jwsRepresentation
                    )
                } else {
                    _ = try await llmClient.addCredits(
                        transactionSignedData: verificationResult.jwsRepresentation
                    )
                }
            case .unverified(_, let err):
                throw err
        }
    }
    
    func _configurePersistenceProvider(_ provider: PersistenceProvider) {
        self.persistenceProvider = provider
        Task {
            await self._refreshConversations()
        }
    }
    
    func _getConversation(by id: String) -> Conversation? {
        return conversations.value?.first { $0.id == id }
    }

}
