//
//  Clarity_FinanceApp.swift
//  Clarity Finance
//
//  Created by Sukhman Singh on 5/8/26.
//

import SwiftUI

@main
struct Clarity_FinanceApp: App {
    @State private var store = FinanceStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
