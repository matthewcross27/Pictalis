import Combine
import Foundation
import Supabase

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var userId: UUID?

    private let client: SupabaseClient

    // Expose the SupabaseClient so UploadService can reach Storage.
    let supabase: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
        self.supabase = client
    }

    func signInIfNeeded() async {
        do {
            if let session = client.auth.currentSession {
                userId = session.user.id
                isAuthenticated = true
            } else {
                let session = try await client.auth.signInAnonymously()
                userId = session.user.id
                isAuthenticated = true
            }
        } catch {
            print("Auth error: \(error)")
        }
    }

    var accessToken: String? {
        client.auth.currentSession?.accessToken
    }
}
