//
//  Clarity_FinanceApp.swift
//  Clarity Finance
//
//  Created by Sukhman Singh on 5/8/26.
//

import SwiftUI

@main
struct Clarity_FinanceApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(ClarityAppDelegate.self) private var appDelegate
    #endif

    @State private var store: FinanceStore

    @MainActor
    init() {
        _store = State(initialValue: FinanceStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
