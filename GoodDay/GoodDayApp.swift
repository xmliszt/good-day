//
//  GoodDayApp.swift
//  GoodDay
//
//  Created by Li Yuxuan on 10/8/25.
//

import SwiftUI
import SwiftData

@main
struct GoodDayApp: App {
    @State private var colorScheme: ColorScheme? = UserPreferences.shared.preferredColorScheme
    
    var sharedModelContainer: ModelContainer = {
        
        // 1. Define schemas
        let schema = Schema([
            DayEntry.self
        ])
        
        // 2. Configure for iCloud
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
        )

        // 3. Create the container
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
                    .environment(UserPreferences.shared)
                    .preferredColorScheme(colorScheme)
                    .onAppear {
                        setupColorSchemeObserver()
                    }
            }
        }
        .modelContainer(sharedModelContainer)
    }
    
    private func setupColorSchemeObserver() {
        NotificationCenter.default.addObserver(
            forName: .didChangeColorScheme,
            object: nil,
            queue: .main
        ) { [self] _ in
            colorScheme = UserPreferences.shared.preferredColorScheme
        }
    }
}
