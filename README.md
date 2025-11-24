# LLMKit

LLMKit is a SwiftUI framework for integrating Large Language Model functionality with a clean and intuitive API.

## How to use

```swift
import SwiftUI
import LLMKit

extension LLMClient {
    static var shared = LLMClient(
        authProvider: .xcode(bundleID: "..."),
        uploadProvider: .default,
        uploadPolicy: .automatic
    )
}

struct LLMPersistenceProvider: PersistenceProvider {...}

@main
struct MyApp: App {
    let persistenceController = LLMPersistenceProvider()
  
    var body: some Scene {
        WindowGroup {
            ContentView()
                .llmProvider(
                    client: .shared,
                    persistenceProvider: persistenceController
                )
        }
    }
}
```

## Advanced Configuration (Multi-Window)

When your application contains multiple windows or scenes, you typically need to share a single `LLMState` instance across all windows. This is particularly common in macOS applications where users can open multiple windows simultaneously.

### Implementation

To share state across multiple windows, you need to:

1. **Declare a shared `LLMState` at the App level** using `@State`
2. **Pass the same state instance** to each window's `.llmProvider()` modifier

```swift
import SwiftUI
import LLMKit

@main
struct MyApp: App {
    // Declare shared state at App level
    @State private var llmState = LLMState()

    init() {
        self._llmState = State(initialValue: LLMState(
            llmClient: .shared,
            persistenceProvider: LLMPersistenceProvider()
        ))
    }

    var body: some Scene {
        WindowGroup("Main Window", id: "main") {
            MainView()
                .llmProvider(state: llmState, client: .shared)
                .task {
                    // Refresh conversations somewhere.
                    await llmState.refreshConversations()
                }
        }

        WindowGroup("Secondary Window", id: "secondary") {
            SecondaryView()
                .llmProvider(state: llmState, client: .shared)
        }
    }
}
```
