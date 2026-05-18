//
//  LLMStatable+Streaming.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

// MARK: - Stream publish throttling

/// 控制流式 chunk 写入 `conversation.messages` 的频率。
///
/// 上游 LLM 一秒可能发 20-30 个 chunk, 每个 chunk in-place update messages 会触发
/// `LLMStateObject` / `LLMState` 的 objectWillChange, 进而让所有 observe llmState 的 view
/// (典型场景: AIChatView body) 按这个频率重 evaluate。
///
/// 这个策略**不影响 LLMKit 内部行为** — `AgentExecutor` 有自己的 context 累加, 不读
/// `conversation.messages` 中间态。仅决定"UI 投影"刷新频率。
public enum StreamPublishStrategy: Sendable {
    /// 默认: 每个 chunk 立即写入 messages, publish 频率 = 上游 chunk 频率。
    /// 行为透明, 跟早期版本一致。
    case immediate

    /// 节流: 在窗口内 coalesce 多个 chunk, 窗口结束时按"最后一帧"flush 一次。
    /// 推荐值: `0.033` (30Hz, 适合典型 chat UI), `0.016` (60Hz 对齐显示器), `0.1` (低频长聊天)。
    /// 即便开了节流, 在 round 边界 / 流结束 / cancel 这些关键节点会强制 flush, 不会丢内容。
    case throttled(TimeInterval)
}

/// 内部用的 coalescing 节流器。同 id 的 chunk 内容累积, "最后一帧" 覆盖前面 (因为 content 是
/// 累积字符串, toolCalls 是累积数组, superset 关系天然成立)。
/// `@MainActor` 保证 upsert 闭包跟 conversations 的修改在主线程一致。
@MainActor
final class StreamUpsertThrottler {
    private let strategy: StreamPublishStrategy
    private let upsert: (ChatMessageContent) -> Void

    private var pending: ChatMessageContent?
    private var flushTask: Task<Void, Never>?

    init(
        strategy: StreamPublishStrategy,
        upsert: @escaping (ChatMessageContent) -> Void
    ) {
        self.strategy = strategy
        self.upsert = upsert
    }

    /// 流式 chunk 进来时调用。`.immediate` 模式直跑 upsert; `.throttled` 模式收下作为 pending,
    /// 起 flush task 等待窗口结束。窗口期间内再来的 chunk 覆盖 pending, flush task 不重置。
    func update(_ content: ChatMessageContent) {
        switch strategy {
        case .immediate:
            upsert(content)
        case .throttled(let interval):
            pending = content
            if flushTask == nil {
                flushTask = Task { @MainActor [weak self] in
                    let nanos = UInt64(max(0, interval) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                    self?.flushNow()
                }
            }
        }
    }

    /// 强制立即 flush pending (如果有) 并清理 flush task。
    /// 调用点: 进入 `.tool` 切换前 / loop 结束前 / catch 块里 — 保证关键节点 UI 不滞后。
    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        if let pending {
            upsert(pending)
            self.pending = nil
        }
    }
}


public final class StreamingStore<State: StreamingMessageState> {
    private var streams: [Conversation.ID: State] = [:]

    public init() {}

    public func stream(for id: Conversation.ID) -> State {
        if let existing = streams[id] {
            return existing
        }

        let state = State(conversationID: id)
        streams[id] = state
        return state
    }

    public func removeStream(for id: Conversation.ID) {
        streams[id] = nil
    }

    public func streamIfExists(for id: Conversation.ID) -> (any StreamingMessageState)? {
        streams[id]
    }
}

public protocol StreamingMessageState: AnyObject, Identifiable {
    var id: String { get set }
    var conversationID: Conversation.ID { get set }

    var content: String { get set }
    var files: [ChatMessageContent.File] { get set }
    /// 当前正在 stream 的 assistant 消息是否带 tool calls。带 = 这一轮是中间步骤
    /// (UI 可以渲染成"工具调用进行中"); 空 = 终态/纯回复。
    var toolCalls: [ToolCall] { get set }
    var isFinished: Bool { get set }

    init(conversationID: Conversation.ID)
}
