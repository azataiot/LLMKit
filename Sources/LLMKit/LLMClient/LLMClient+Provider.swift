//
//  LLMClient+Provider.swift
//  LLMKit
//
//  Created by Chocoford
//

import Foundation
import LLMCore

/// Make LLMClient conform to LLMProvider protocol
extension LLMClient: LLMProvider {
    // LLMClient already implements chat() and streamChat() methods
    // They match the protocol requirements, so no additional implementation needed
}
