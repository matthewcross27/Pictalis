import Combine
import Foundation
import Supabase

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var userId: UUID?
    @Published private(set) var authError: String?

    private let client: SupabaseClient

    var storageClient: SupabaseClient { client }

    init(client: SupabaseClient) {
        self.client = client
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
            authError = error.localizedDescription
        }
    }

    var accessToken: String? {
        client.auth.currentSession?.accessToken
    }
}
