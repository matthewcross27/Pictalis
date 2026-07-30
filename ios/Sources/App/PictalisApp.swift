import SwiftUI
import Sentry

import Supabase

@main
struct PictalisApp: App {
    @State private var auth: AuthService
    @State private var api: APIClient

    init() {
        SentrySDK.start { options in
            options.dsn = SentryConfig.dsn
            options.debug = false
            options.tracesSampleRate = 0
        }

        let client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
        let authService = AuthService(client: client)
        let apiClient = APIClient(supabase: client)
        _auth = State(initialValue: authService)
        _api = State(initialValue: apiClient)

        configureNavigationBar()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(api)
                .task { await auth.signInIfNeeded() }
        }
    }

    private func configureNavigationBar() {
        // UIColor values sourced from DesignSystem.swift color tokens (same RGB).
        let inkColor = UIColor(red: 0.157, green: 0.141, blue: 0.098, alpha: 1)   // Color.ink
        let bgColor  = UIColor(red: 0.976, green: 0.961, blue: 0.945, alpha: 0.97) // Color.filmWhite @ 97%
        let dividerColor = UIColor(red: 0.855, green: 0.835, blue: 0.804, alpha: 0.6) // Color.divider @ 60%
        let amberColor   = UIColor(red: 0.700, green: 0.480, blue: 0.060, alpha: 1)   // Color.amber

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = bgColor
        appearance.shadowColor = dividerColor

        // Font.titleSerif equivalent: Fraunces-SemiBold 17
        let titleFont = UIFont(name: "Fraunces-SemiBold", size: 17) ?? UIFont.boldSystemFont(ofSize: 17)
        appearance.titleTextAttributes = [.font: titleFont, .foregroundColor: inkColor]

        // Font.displaySerif equivalent: Fraunces-SemiBold 34
        let largeTitleFont = UIFont(name: "Fraunces-SemiBold", size: 34) ?? UIFont.boldSystemFont(ofSize: 34)
        appearance.largeTitleTextAttributes = [.font: largeTitleFont, .foregroundColor: inkColor]

        UINavigationBar.appearance().standardAppearance   = appearance
        UINavigationBar.appearance().compactAppearance    = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().tintColor = amberColor
    }
}
