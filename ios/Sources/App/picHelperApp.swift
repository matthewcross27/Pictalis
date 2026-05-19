import SwiftUI
import Supabase

@main
struct picHelperApp: App {
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(api)
                .task { await auth.signInIfNeeded() }
        }
    }
}
