//
//  UIWindow.swift
//  GoodDay
//
//  Created by Li Yuxuan on 14/8/25.
//

import SwiftUI

/// UIWindow extension to detect shake motion
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
