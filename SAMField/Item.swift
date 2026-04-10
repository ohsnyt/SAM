//
//  Item.swift
//  SAMField
//
//  Created by David Snyder on 4/8/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
