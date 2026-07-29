import Foundation
import Observation
import Supabase

@Observable
@MainActor
final class AuthService {
    private(set) var isAuthenticated = false
    private(set) var userId: UUID?
    private(set) var authError: (any Error)?

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
            authError = error
        }
    }

    var accessToken: String? {
        client.auth.currentSession?.accessToken
    }
}
