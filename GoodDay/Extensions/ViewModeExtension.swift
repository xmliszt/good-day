//
//  ViewMode.swift
//  GoodDay
//
//  Created by Li Yuxuan on 14/8/25.
//

import Foundation

enum ViewMode {
    case now
    case year
}


extension ViewMode: CaseIterable {
    var rawValue: String {
        switch self {
        case .now: return "now"
        case .year: return "year"
        }
    }
    
    init?(rawValue: String) {
        switch rawValue {
        case "now": self = .now
        case "year": self = .year
        default: return nil
        }
    }
    
    var displayName: String {
        switch self {
        case .now: return "Now"
        case .year: return "Year"
        }
    }
}
