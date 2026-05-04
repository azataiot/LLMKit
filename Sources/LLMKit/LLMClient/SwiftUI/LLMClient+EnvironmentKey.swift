//
//  File.swift
//  LLMKit
//
//  Created by Chocoford on 9/5/25.
//

#if canImport(SwiftUI)
import SwiftUI
import Combine

import Logging

private struct LLMClientKey: EnvironmentKey {
    static let defaultValue: LLMClient = .init()
}

extension EnvironmentValues {
    public var llmClient: LLMClient {
        get { self[LLMClientKey.self] }
        set { self[LLMClientKey.self] = newValue }
    }
}

struct LLMStateObjectProvider: View {
    var content: (any LLMStatable) -> AnyView
    
    init<Content: View>(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?,
        @ViewBuilder content: @escaping (any LLMStatable) -> Content
    ) {
        self._state = StateObject(
            wrappedValue: LLMStateObject(llmClient: llmClient, persistenceProvider: persistenceProvider)
        )
        self.content = {
            AnyView(content($0))
        }
    }
    @StateObject private var state: LLMStateObject
    
    var body: some View {
        content(state)
            .environmentObject(state)
    }
}

@available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
struct LLMObservableStateProvider: View {
    var content: (any LLMStatable) -> AnyView
    
    init<Content: View>(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?,
        @ViewBuilder content: @escaping (any LLMStatable) -> Content
    ) {
        self._state = State(
            initialValue: LLMState(llmClient: llmClient, persistenceProvider: persistenceProvider)
        )
        self.content = {
            AnyView(content($0))
        }
    }
    @State private var state: LLMState
    
    var body: some View {
        content(state)
            .environment(state)
    }
}


struct LLMStateProvider: View {
    var llmClient: LLMClient
    var persistenceProvider: PersistenceProvider?
    var lagacy: Bool
    var content: (any LLMStatable) -> AnyView

    init<Content: View>(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?,
        lagacy: Bool = false,
        @ViewBuilder content: @escaping (any LLMStatable) -> Content
    ) {
        self.llmClient = llmClient
        self.persistenceProvider = persistenceProvider
        self.lagacy = lagacy
        self.content = {
            AnyView(content($0))
        }
    }
    
    var body: some View {
        if #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *), !lagacy {
            LLMObservableStateProvider(llmClient: llmClient, persistenceProvider: persistenceProvider) { state in
                content(state)
                    .task {
                        await state.refreshConversations()
                    }
            }
        } else {
            LLMStateObjectProvider(llmClient: llmClient, persistenceProvider: persistenceProvider) { state in
                content(state)
                    .task {
                        await state.refreshConversations()
                    }
            }
        }
    }
}

public struct LLMClientProvider: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    
    let logger = Logger(label: "LLMClientProvider")

    var llmState: (any LLMStatable)?
    let llmClient: LLMClient
    var persistenceProvider: PersistenceProvider?
    var lagacy: Bool
    
    internal init(
        state: (any LLMStatable)?,
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?,
        lagacy: Bool = false
    ) {
        self.llmState = state
        self.llmClient = llmClient
        self.persistenceProvider = persistenceProvider
        self.lagacy = lagacy
    }
    
    
    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    public static func modern(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?
    ) -> LLMClientProvider {
        LLMClientProvider(
            state: nil,
            llmClient: llmClient,
            persistenceProvider: persistenceProvider,
            lagacy: false
        )
    }
    
    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    public static func modern(
        state: LLMState,
        llmClient: LLMClient,
    ) -> LLMClientProvider {
        LLMClientProvider(
            state: state,
            llmClient: llmClient,
            persistenceProvider: nil,
            lagacy: false
        )
    }
    
    public static func lagacy(
        llmClient: LLMClient,
        persistenceProvider: PersistenceProvider?
    ) -> LLMClientProvider {
        LLMClientProvider(
            state: nil,
            llmClient: llmClient,
            persistenceProvider: persistenceProvider,
            lagacy: true
        )
    }
    
    public static func lagacy(
        state: LLMStateObject,
        llmClient: LLMClient,
    ) -> LLMClientProvider {
        LLMClientProvider(
            state: state,
            llmClient: llmClient,
            persistenceProvider: nil,
            lagacy: true
        )
    }
    
    @State private var refreshCreditsPassthrough = PassthroughSubject<Void, Never>()

    public func body(content: Content) -> some View {
        if let llmState {
            content
                .modifier(LLMClientProviderContent(llmClient: llmClient, state: llmState))
                .withLLMStateEnvironment(llmState)
        } else {
            LLMStateProvider(
                llmClient: llmClient,
                persistenceProvider: persistenceProvider,
                lagacy: lagacy
            ) { state in
                content
                    .modifier(LLMClientProviderContent(llmClient: llmClient, state: state))
            }
        }
    }
}

struct LLMClientProviderContent: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    
    let logger = Logger(label: "LLMClientProvider")
    var llmClient: LLMClient
    var state: any LLMStatable
    
    @State private var refreshCreditsPassthrough = PassthroughSubject<Void, Never>()

    func body(content: Content) -> some View {
        content
            .environment(\.llmClient, llmClient)
            .onReceive(llmClient.creditsUpdatePublisher) { creditsInfo in
                logger.info("Credits updated: \(creditsInfo.balance)")
                state.updateCreditsInfo(creditsInfo)
            }
            .onReceive(llmClient.authStateChangedPublisher) { isAuthenticated in
                state.isAuthenticated = isAuthenticated
            }
            .onReceive(refreshCreditsPassthrough.throttle(for: 30.0, scheduler: RunLoop.main, latest: true)) { _ in
                guard state.isAuthenticated else { return }
                Task {
                    do {
                        let creditsInfo = try await llmClient.getCredits()
                        state.updateCreditsInfo(creditsInfo)
                    } catch {
                        print("Failed to refresh credits: \(error)")
                    }
                }
            }
            .onChange(of: scenePhase) { newValue in
                if newValue == .active {
                    refreshCreditsPassthrough.send()
                }
            }
            .onAppear {
                refreshCreditsPassthrough.send()
            }
    }
}



extension View {
    @ViewBuilder
    func withLLMStateEnvironment(_ state: any LLMStatable) -> some View {
        if #available(macOS 14.0, iOS 17.0, *), let state = state as? LLMState {
            environment(state)
        } else if let state = state as? LLMStateObject {
            environmentObject(state)
        } else {
            self
        }
    }
    
    
    @ViewBuilder
    public func llmProvider(
        client: LLMClient,
        persistenceProvider: PersistenceProvider?,
        lagacy: Bool = false,
    ) -> some View {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), !lagacy {
            modifier(
                LLMClientProvider.modern(
                    llmClient: client,
                    persistenceProvider: persistenceProvider
                )
            )
        } else if lagacy {
            modifier(
                LLMClientProvider.lagacy(
                    llmClient: client,
                    persistenceProvider: persistenceProvider
                )
            )
        } else {
            self.onAppear {
                fatalError("Not support")
            }
        }
    }
    
    @available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *)
    @ViewBuilder
    public func llmProvider(
        state: LLMState,
        client: LLMClient,
    ) -> some View {
        modifier(
            LLMClientProvider.modern(
                state: state,
                llmClient: client,
            )
        )
    }
    
    @ViewBuilder
    public func llmProvider(
        state: LLMStateObject,
        client: LLMClient,
    ) -> some View {
        modifier(
            LLMClientProvider.lagacy(
                state: state,
                llmClient: client,
            )
        )
    }
}


#endif // canImport(SwiftUI)
