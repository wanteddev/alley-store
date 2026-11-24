import Fluent
import Foundation

/// 만료 감시가 무엇을 어느 단계까지 알렸는지 (ADR-0084).
///
/// 감시 대상 하나에 한 행이다. 이것이 없으면 쓸고 지나갈 때마다 같은 말을 한다.
/// 30일 전 알림이 엿새 동안 하루 네 번씩 오면 그다음 것은 아무도 안 읽는다.
///
/// **행이 없으면 "아직 아무것도 알리지 않았다" 이다.** 만료가 멀어지면(갱신했다면)
/// 행을 지운다. 그래야 다음 주기에 30일 단계부터 다시 시작한다.
final class ExpiryNotice: Model, @unchecked Sendable {
    static let schema = "expiry_notices"

    @ID(key: .id)
    var id: UUID?

    /// 무엇에 대한 것인지. `certificate:<ASC id>`, `membership` 처럼 대상이 정한다
    /// (`ExpiringThing.subject`).
    @Field(key: "subject")
    var subject: String

    /// 알릴 때 본 만료 시각. 날짜를 모르는 대상이면 비어 있다.
    ///
    /// 이 값이 바뀌면 다른 것으로 본다. 멤버십 만료일을 새로 적었거나 같은 이름으로
    /// 인증서를 다시 받은 경우다. 그때는 단계를 처음부터 다시 센다.
    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    /// 마지막으로 알린 단계 (`ExpiryStage.rawValue`).
    @Field(key: "stage")
    var stage: String

    @Field(key: "notified_at")
    var notifiedAt: Date

    init() {}

    init(subject: String, expiresAt: Date?, stage: String, notifiedAt: Date) {
        self.subject = subject
        self.expiresAt = expiresAt
        self.stage = stage
        self.notifiedAt = notifiedAt
    }
}

/// 만료 정보를 읽어오지 못하고 있는 곳 (ADR-0084).
///
/// App Store Connect 를 못 읽으면 인증서 만료도 볼 수 없다. 그런데 그 사실 자체를
/// 아무에게도 말하지 않으면, 감시가 돌고 있는 줄 아는 채로 인증서가 만료된다. 그래서
/// 실패가 언제부터 이어졌는지 적어두고, 하루를 넘기면 한 번 알린다. 다시 읽히면
/// 행을 지운다.
final class ExpirySourceFailure: Model, @unchecked Sendable {
    static let schema = "expiry_source_failures"

    @ID(key: .id)
    var id: UUID?

    /// 어느 곳인지 (`ExpirySource.id`).
    @Field(key: "source")
    var source: String

    /// 이번 실패가 시작된 때. 사이에 한 번이라도 읽히면 행이 지워지므로 연속 실패의
    /// 시작이다.
    @Field(key: "failing_since")
    var failingSince: Date

    /// 가장 최근 실패의 이유. 알림에 그대로 싣는다.
    @Field(key: "last_error")
    var lastError: String

    /// 알린 때. 다시 읽힐 때까지 또 알리지 않는다.
    @OptionalField(key: "alerted_at")
    var alertedAt: Date?

    init() {}

    init(source: String, failingSince: Date, lastError: String) {
        self.source = source
        self.failingSince = failingSince
        self.lastError = lastError
    }
}

/// 만료 감시가 쓰는 두 표 (ADR-0084).
public struct CreateExpiryWatch: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(ExpiryNotice.schema)
            .id()
            .field("subject", .string, .required)
            .field("expires_at", .datetime)
            .field("stage", .string, .required)
            .field("notified_at", .datetime, .required)
            .unique(on: "subject")
            .create()

        try await database.schema(ExpirySourceFailure.schema)
            .id()
            .field("source", .string, .required)
            .field("failing_since", .datetime, .required)
            .field("last_error", .string, .required)
            .field("alerted_at", .datetime)
            .unique(on: "source")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(ExpirySourceFailure.schema).delete()
        try await database.schema(ExpiryNotice.schema).delete()
    }
}
