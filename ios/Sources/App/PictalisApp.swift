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
        // Bridge DesignSystem's SwiftUI tokens instead of duplicating raw RGB/font values,
        // so this stays in sync if the palette or type scale ever changes.
        let inkColor     = UIColor(Color.ink)
        let bgColor      = UIColor(Color.filmWhite.opacity(0.97))
        let dividerColor = UIColor(Color.divider.opacity(0.6))
        let amberColor   = UIColor(Color.amber)

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = bgColor
        appearance.shadowColor = dividerColor

        // Font.titleSerif equivalent: Fraunces-Medium 17
        let titleFont = UIFont(name: "Fraunces-Medium", size: 17) ?? UIFont.boldSystemFont(ofSize: 17)
        appearance.titleTextAttributes = [.font: titleFont, .foregroundColor: inkColor]

        // Font.displaySerif equivalent: Fraunces-SemiBold 36
        let largeTitleFont = UIFont(name: "Fraunces-SemiBold", size: 36) ?? UIFont.boldSystemFont(ofSize: 36)
        appearance.largeTitleTextAttributes = [.font: largeTitleFont, .foregroundColor: inkColor]

        UINavigationBar.appearance().standardAppearance   = appearance
        UINavigationBar.appearance().compactAppearance    = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().tintColor = amberColor
    }
}
