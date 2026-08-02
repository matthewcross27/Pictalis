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
    let status: String
    let photoCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case photoCount = "photo_count"
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
    let comparisonCount: Int
    let signedUrl: URL

    enum CodingKeys: String, CodingKey {
        case id
        case comparisonCount = "comparison_count"
        case signedUrl = "signed_url"
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
    let id: UUID
    let eloRating: Double
    let isSuppressed: Bool
    let signedUrl: URL

    enum CodingKeys: String, CodingKey {
        case id
        case eloRating       = "elo_rating"
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
    var synced: Bool

    enum CodingKeys: String, CodingKey {
        case photoId    = "photo_id"
        case decision
        case synced
    }
}

struct SessionDecisionFile: Codable {
    var decisions: [StoredDecision]
}

// MARK: - batch-submit-cull

struct BatchDecisionResult: Decodable {
    let photoId: UUID
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case success
    }
}

struct BatchSubmitResponse: Decodable {
    let results: [BatchDecisionResult]
}
