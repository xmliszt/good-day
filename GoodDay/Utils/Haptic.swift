//
//  Haptic.swift
//  GoodDay
//
//  Created by Li Yuxuan on 14/8/25.
//

import UIKit

struct Haptic {
    
    /**
     Play a haptic with given intensity
     
     - Parameters: with intensity: feedback intensity, default light
     */
    static func play(with intensity: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let isHapticEnabled = UserPreferences.shared.enableHaptic;
        guard isHapticEnabled else { return }
        
        let impactFeedback = UIImpactFeedbackGenerator(style: intensity)
        impactFeedback.impactOccurred()
    }
}
