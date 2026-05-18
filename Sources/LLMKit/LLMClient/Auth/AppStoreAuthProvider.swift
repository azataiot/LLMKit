//
//  AppStoreAuthProvider.swift
//  LLMKit
//
//  Created by Chocoford on 9/12/25.
//

import Foundation
import LLMCore
#if canImport(StoreKit)
import StoreKit
import Logging

public struct AppStoreAuthProvider: LLMAuthProvider {
    private let logger = Logger(label: "AppStoreAuthProvider")
    
    public let networking: LLMNetworking
    private let bundleID: String
    private let ascAppID: Int64?
    private let subscriptionGroupID: String?

    public init(
        networking: LLMNetworking,
        bundleID: String,
        ascAppID: Int64?,
        subscriptionGroupID: String?
    ) {
        self.networking = networking
        self.bundleID = bundleID
        self.ascAppID = ascAppID
        self.subscriptionGroupID = subscriptionGroupID
    }

    public func restoreAuth() async throws -> String {
        if let subscriptionGroupID {
            return try await restoreSubscriptionAuth(groupID: subscriptionGroupID)
        }

        return try await AnonAuthProvider(networking: self.networking).anonAuth(bundleID: bundleID)
    }

    private func restoreSubscriptionAuth(groupID: String) async throws -> String {
        do {
            /// Asynchronously advances to the next element and returns it, or ends the sequence if there is no next element.
            /// 会一次性把所有的 transaction 都遍历完
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result,
                   transaction.subscriptionGroupID == groupID {
                    logger.info("Found existing entitlement: \(transactionRestoreLog(transaction, source: "currentEntitlements"))")
                    return try await restoreAuth(transactionJWS: result.jwsRepresentation)
                }
            }

            logger.info("No current entitlement found for subscriptionGroupID=\(groupID); scanning Transaction.all")

            if let result = await latestHistoricalTransaction(matching: { transaction in
                transaction.subscriptionGroupID == groupID
            }), case .verified(let transaction) = result {
                logger.info("Found historical transaction: \(transactionRestoreLog(transaction, source: "Transaction.all"))")
                return try await restoreAuth(transactionJWS: result.jwsRepresentation)
            }
            
            return try await AnonAuthProvider(networking: self.networking).anonAuth(bundleID: bundleID)
        } catch {
            logger.error("Restore auth error: \(error.localizedDescription)")
            throw error
        }
    }

    private func latestHistoricalTransaction(
        matching predicate: @escaping @Sendable (Transaction) -> Bool
    ) async -> VerificationResult<Transaction>? {
        var latestResult: VerificationResult<Transaction>?
        var latestDate = Date.distantPast

        for await result in Transaction.all {
            guard case .verified(let transaction) = result,
                  predicate(transaction) else { continue }

            let transactionDate = transaction.signedDate
            if transactionDate > latestDate {
                latestResult = result
                latestDate = transactionDate
            }
        }

        return latestResult
    }

    private func transactionRestoreLog(_ transaction: Transaction, source: String) -> String {
        """
        source=\(source), \
        id=\(transaction.id), \
        originalID=\(transaction.originalID), \
        productID=\(transaction.productID), \
        subscriptionGroupID=\(transaction.subscriptionGroupID ?? "nil"), \
        purchaseDate=\(formatRestoreLogDate(transaction.purchaseDate)), \
        expirationDate=\(formatRestoreLogDate(transaction.expirationDate)), \
        signedDate=\(formatRestoreLogDate(transaction.signedDate)), \
        revocationDate=\(formatRestoreLogDate(transaction.revocationDate))
        """
    }

    private func formatRestoreLogDate(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return ISO8601DateFormatter().string(from: date)
    }
    
    private func restoreAuth(transactionJWS: String) async throws -> String {
        struct RestoreResponse: Codable { let token: String }
        let req = IAPAuthRequest(
            jws: transactionJWS,
            bundleID: bundleID,
            ascAppID: ascAppID,
            anonID: AnonIdentityManager.loadAnonID(for: bundleID)
        )
        let data: RestoreResponse = try await networking.post("/auth/iap", body: req)
        
        return data.token
    }

    public func handleSubscriptionPurchase(transactionJWS: String) async throws -> String {
        try await restoreAuth(transactionJWS: transactionJWS)
    }

    public func handlePurchase(transactionJWS: String) async throws -> CreditsInfo {
        let req = CreditAddRequest(
            transactionSignedData: transactionJWS,
            bundleID: bundleID,
            ascAppID: ascAppID
        )
        
        let data: CreditsInfo = try await networking.post("/credits/add", body: req)
        return data
    }

    @available(*, deprecated, message: "Transaction update listening is no longer handled here. Configure subscriptionGroupID and call restore() / syncSubscriptionState() from LLMClient.")
    public func listenTrasacionsUpdates(productIDs: [String]) {
        fatalError("listenTrasacionsUpdates(productIDs:) is deprecated. Configure subscriptionGroupID and call restore() / syncSubscriptionState() from LLMClient.")
    }

}

public struct AppStoreAuthProviderBuilder: LLMAuthProviderBuilder {
    var bundleID: String
    var ascAppID: Int64?
    var subscriptionGroupID: String?
    
    public func callAsFunction(_ networking: LLMNetworking) -> any LLMAuthProvider {
        AppStoreAuthProvider(
            networking: networking,
            bundleID: bundleID,
            ascAppID: ascAppID,
            subscriptionGroupID: subscriptionGroupID
        )
    }
}

extension LLMAuthProviderBuilder where Self == AppStoreAuthProviderBuilder {
    /// Build an App Store auth provider.
    ///
    /// Pass `subscriptionGroupID` when the app wants `restore()` / `syncSubscriptionState()` to
    /// recover an existing subscription identity from StoreKit. Purchase completion should pass
    /// the verified JWS through `completeSubscriptionPurchase(transactionSignedData:)`.
    /// Routine `Transaction.updates` handling should usually stay in the app and App Store Server
    /// Notifications should drive long-term server-side lifecycle changes.
    public static func appStore(
        bundleID: String,
        ascAppID: Int64,
        subscriptionGroupID: String? = nil
    ) -> AppStoreAuthProviderBuilder {
        AppStoreAuthProviderBuilder(
            bundleID: bundleID,
            ascAppID: ascAppID,
            subscriptionGroupID: subscriptionGroupID
        )
    }

    /// Build an Xcode StoreKit-testing auth provider.
    ///
    /// `subscriptionGroupID` has the same restore/reconciliation meaning as the production
    /// App Store provider, but transactions are sent without an ASC app ID.
    public static func xcode(
        bundleID: String,
        subscriptionGroupID: String? = nil
    ) -> AppStoreAuthProviderBuilder {
        AppStoreAuthProviderBuilder(
            bundleID: bundleID,
            ascAppID: nil,
            subscriptionGroupID: subscriptionGroupID
        )
    }
}

#endif // canImport(StoreKit)
