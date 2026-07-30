import Foundation

extension UUID {
    // Backend zod schemas validate session/photo ids as lowercase UUID strings.
    var lowercased: String { uuidString.lowercased() }
}

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
    let stage: String?

    enum CodingKeys: String, CodingKey {
        case comparisonId = "comparison_id"
        case photoA = "photo_a"
        case photoB = "photo_b"
        case stage
    }
}

struct PairPhoto: Decodable, Identifiable, Equatable {
    let id: UUID
    let storagePath: String
    let thumbnailPath: String?
    let eloRating: Double
    let comparisonCount: Int
    let signedUrl: URL

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
    let session: SessionInfo?
}

struct SessionInfo: Decodable {
    let stage: String
    let isComplete: Bool

    enum CodingKeys: String, CodingKey {
        case stage
        case isComplete = "is_complete"
    }
}

struct RankedPhoto: Decodable, Identifiable, Equatable {
    let id:              UUID
    let storagePath:     String
    let thumbnailPath:   String?
    let eloRating:       Double
    let uncertainty:     Double?
    let comparisonCount: Int
    let isSuppressed:    Bool
    let signedUrl:       URL

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath     = "storage_path"
        case thumbnailPath   = "thumbnail_path"
        case eloRating       = "elo_rating"
        case uncertainty
        case comparisonCount = "comparison_count"
        case isSuppressed    = "is_suppressed"
        case signedUrl       = "signed_url"
    }
}

// MARK: - session-status

struct SessionStatus: Decodable {
    let stage: String
    let isComplete: Bool
    let topPhotoCount: Int
    let totalComparisons: Int

    enum CodingKeys: String, CodingKey {
        case stage
        case isComplete = "is_complete"
        case topPhotoCount = "top_photo_count"
        case totalComparisons = "total_comparisons"
    }
}

// MARK: - start-cull

struct StartCullResponse: Decodable {
    let stage: String
}

// MARK: - Errors

struct APIErrorResponse: Decodable {
    let error: String
}

// MARK: - CullDecision

enum CullDecision: String, Codable, Sendable {
    case keep
    case drop
}

// MARK: - DecisionStore types

struct StoredDecision: Codable, Sendable {
    let photoId: UUID
    let decision: CullDecision
    let timestamp: Date
    var synced: Bool

    enum CodingKeys: String, CodingKey {
        case photoId    = "photo_id"
        case decision
        case timestamp
        case synced
    }
}

struct SessionDecisionFile: Codable {
    let sessionId: UUID
    var decisions: [StoredDecision]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case decisions
    }
}

// MARK: - batch-submit-cull

struct BatchDecisionResult: Decodable {
    let photoId:  UUID
    let success:  Bool
    let error:    String?

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case success
        case error
    }
}

struct BatchSubmitResponse: Decodable {
    let results: [BatchDecisionResult]
}
