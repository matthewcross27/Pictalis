import Foundation

// MARK: - create-session

struct CreateSessionResponse: Decodable {
    let session: APISession
}

struct APISession: Decodable {
    let id: UUID
    let createdAt: String
    let expiresAt: String
    let status: String
    let photoCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case status
        case photoCount = "photo_count"
    }
}

// MARK: - register-photo

struct RegisterPhotoResponse: Decodable {
    let photo: RegisteredPhoto
}

struct RegisteredPhoto: Decodable {
    let id: UUID
    let sessionId: UUID
    let storagePath: String
    let eloRating: Double
    let comparisonCount: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case storagePath = "storage_path"
        case eloRating = "elo_rating"
        case comparisonCount = "comparison_count"
        case createdAt = "created_at"
    }
}

// MARK: - next-pair

struct NextPairResponse: Decodable {
    let comparisonId: UUID
    let photoA: PairPhoto
    let photoB: PairPhoto

    enum CodingKeys: String, CodingKey {
        case comparisonId = "comparison_id"
        case photoA = "photo_a"
        case photoB = "photo_b"
    }
}

struct PairPhoto: Decodable, Identifiable {
    let id: UUID
    let storagePath: String
    let thumbnailPath: String?
    let eloRating: Double
    let comparisonCount: Int
    let signedUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case thumbnailPath = "thumbnail_path"
        case eloRating = "elo_rating"
        case comparisonCount = "comparison_count"
        case signedUrl = "signed_url"
    }
}

// MARK: - submit-comparison

struct SubmitComparisonResponse: Decodable {
    let winnerId: UUID
    let loserId: UUID
    let winnerNewRating: Double
    let loserNewRating: Double

    enum CodingKeys: String, CodingKey {
        case winnerId = "winner_id"
        case loserId = "loser_id"
        case winnerNewRating = "winner_new_rating"
        case loserNewRating = "loser_new_rating"
    }
}

// MARK: - results

struct ResultsResponse: Decodable {
    let photos: [RankedPhoto]
}

struct RankedPhoto: Decodable, Identifiable {
    let id: UUID
    let storagePath: String
    let thumbnailPath: String?
    let eloRating: Double
    let uncertainty: Double?
    let comparisonCount: Int
    let isSuppressed: Bool
    let clusterId: String?
    let signedUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case thumbnailPath = "thumbnail_path"
        case eloRating = "elo_rating"
        case uncertainty
        case comparisonCount = "comparison_count"
        case isSuppressed = "is_suppressed"
        case clusterId = "cluster_id"
        case signedUrl = "signed_url"
    }
}

// MARK: - Errors

struct APIErrorResponse: Decodable {
    let error: String
}
