//
//  Item.swift
//  Clarity Finance
//
//  Created by Sukhman Singh on 5/8/26.
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
