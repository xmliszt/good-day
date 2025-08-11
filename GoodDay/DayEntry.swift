//
//  Item.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import Foundation
import SwiftData

@Model
final class DayEntry {
    var body: String
    var createdAt: Date
    
    init(body: String, createdAt: Date) {
        self.body = body
        self.createdAt = createdAt
    }
}
