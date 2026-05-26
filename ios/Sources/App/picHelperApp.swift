import SwiftUI
import Supabase

@main
struct PictalisApp: App {
    @StateObject private var auth: AuthService
    @StateObject private var api: APIClient

    init() {
        let client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
        let authService = AuthService(client: client)
        let apiClient = APIClient(supabase: client)
        _auth = StateObject(wrappedValue: authService)
        _api = StateObject(wrappedValue: apiClient)

        configureNavigationBar()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(api)
                .task { await auth.signInIfNeeded() }
        }
    }

    private func configureNavigationBar() {
        let inkColor = UIColor(red: 0.157, green: 0.141, blue: 0.098, alpha: 1)
        let bgColor  = UIColor(red: 0.976, green: 0.961, blue: 0.945, alpha: 0.97)

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = bgColor
        appearance.shadowColor = UIColor(red: 0.855, green: 0.835, blue: 0.804, alpha: 0.6)

        let titleFont = UIFont(name: "Fraunces-SemiBold", size: 17) ?? UIFont.boldSystemFont(ofSize: 17)
        appearance.titleTextAttributes = [.font: titleFont, .foregroundColor: inkColor]

        let largeTitleFont = UIFont(name: "Fraunces-SemiBold", size: 34) ?? UIFont.boldSystemFont(ofSize: 34)
        appearance.largeTitleTextAttributes = [.font: largeTitleFont, .foregroundColor: inkColor]

        UINavigationBar.appearance().standardAppearance  = appearance
        UINavigationBar.appearance().compactAppearance   = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().tintColor = UIColor(red: 0.700, green: 0.480, blue: 0.060, alpha: 1)
    }
}
