//
//  LLMStatable+Utilities.swift
//  LLMKit
//

import Foundation
import StoreKit
import LLMCore
import Logging
import ChocofordEssentials

extension LLMStatable {
    func updateCreditsInfo(_ creditsInfo: CreditsInfo) {
        self.creditsInfo = creditsInfo
    }

    /// 这条 message 是不是当前正在接收 assistant token。
    /// - 一个 conversation 同时只有一条 assistant chunk 在流, 不会多条命中。
    /// - agent 多轮 loop 里, 上一轮 chunk 流完后会被自动标完成。
    /// - tool call 执行、approval 等待、两轮 agent request 间隙都不表达为某条 message streaming。
    /// - 整个 agent loop 收尾后 streamState 被 removeStream 清掉, 任何 message 都返回 false。
    /// SwiftUI 渲染"打字 indicator"或"流式光标"时读这个; 判断整条 run 是否还在跑用 `_isRunning`。
    func _isStreaming(messageID: String, in conversationID: String) -> Bool {
        guard let stream = streamingStore.streamIfExists(for: conversationID) else {
            return false
        }
        return stream.id == messageID && !stream.isFinished
    }

    /// Conversation-level run state. 用于输入框禁用、stop 按钮、全局 loading 等。
    /// `sendMessage` 中新 user message 插入后才 true; `resumeGeneration` 中尾部 error stub 清理后才 true。
    /// 跟 `_isStreaming` 不同, tool call / approval / agent 下一轮请求间隙也返回 true。
    func _isRunning(conversationID: String) -> Bool {
        runningConversationIDs.contains(conversationID)
    }

    /// 估算指定 conversation 当前活跃上下文 (`contextMessages`) 消耗的 token 数。
    ///
    /// **保守估算, 不是真实 tokenizer 结果**, 用法上当 ballpark, 不要当精确门槛:
    /// - 中文 / 日文 / 韩文 (CJK) 占比 > 50% → 按 1 char ≈ 1 token (CJK 真实可能 1.5-2)
    /// - 含 `{` 或 `function`/`return` 等代码特征 → 按 2 chars ≈ 1 token (代码 / JSON)
    /// - 其余 (英文文本主导) → 按 4 chars ≈ 1 token
    ///
    /// 误差 10-30% 常见, 极端情况可能更大。**真正防溢出靠 `_runAgentLoop` 的反应式兜底**
    /// (上游报 context_length_exceeded → 自动 compact + 重试)。这个估算只用于:
    /// - "现在距离 model.maxContextTokens 还有多远"的 ballpark
    /// - UI 展示一个进度条
    /// - 主动触发 compact 的预防性阈值 (~70% 比 ~95% 安全得多)
    func _estimatedTokenUsage(in conversationID: String) -> Int {
        guard let conv = self.conversations.value?.first(where: { $0.id == conversationID }) else {
            return 0
        }
        var total = 0
        for msg in conv.messages.contextMessages {
            if let content = msg.content {
                total += Self.estimateTokens(in: content)
            }
            for call in msg.toolCalls ?? [] {
                total += Self.estimateTokens(in: call.name)
                total += Self.estimateTokens(in: call.arguments)
            }
        }
        return total
    }

    /// 启发式估算一段文本的 token 数。见 `_estimatedTokenUsage` 文档说明各档系数。
    private static func estimateTokens(in text: String) -> Int {
        if text.isEmpty { return 0 }

        // CJK 检测: Unicode 范围内 CJK 统一汉字 / 平假 / 片假 / 谚文。
        // 占比超半就认定 CJK 主导, 取保守的 1 char / token。
        let cjkCount = text.unicodeScalars.reduce(0) { count, scalar in
            let v = scalar.value
            let isCJK = (0x4E00...0x9FFF).contains(v)    // 统一汉字
                || (0x3040...0x309F).contains(v)         // 平假名
                || (0x30A0...0x30FF).contains(v)         // 片假名
                || (0xAC00...0xD7AF).contains(v)         // 谚文
            return count + (isCJK ? 1 : 0)
        }
        if cjkCount * 2 > text.count {
            return text.count
        }

        // 代码 / JSON 检测: 含明显结构符号或常见 code 关键词, 取 2 chars / token。
        // 不必非常精确, 命中即可保守估。
        if text.contains("{") || text.contains("function") || text.contains("return ")
            || text.contains("import ") || text.contains("=>") || text.contains("];") {
            return text.count / 2
        }

        // 默认: 英文文本主导, 4 chars / token (BPE 经验值)。
        return text.count / 4
    }

}
