//
//  DateFormatter.swift
//  GoodDay
//
//  Created by Li Yuxuan on 14/8/25.
//

import Foundation

extension DateFormatter {
    static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()
}
