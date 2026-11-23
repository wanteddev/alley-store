import Fluent
import Foundation
import SQLKit
import Vapor

/// 스토어가 그 앱에 발급해 둔 Developer ID 프로비저닝 프로필 (ADR-0084).
///
/// 앱마다 하나다. 다시 발급하면 이 행을 바꾸고 Apple 쪽 옛 프로필은 지운다. 프로필은
/// Apple 이 고칠 수 없게 해 둬서 다시 만드는 것 말고 방법이 없다.
///
/// **비밀이 아니다.** 인증서의 공개 부분과 허용 권한을 Apple 이 서명해 둔 파일이고,
/// 이것만으로 서명할 수는 없다. 서명 키는 워커 맥의 키체인에만 있다 (ADR-0002).
public final class IssuedProfile: Model, @unchecked Sendable {
    public static let schema = "provisioning_profiles"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "app_id")
    public var app: App

    /// App Store Connect 쪽 ID. 다시 발급할 때 옛 것을 지우는 데 쓴다.
    @Field(key: "asc_profile_id")
    public var ascProfileID: String

    @Field(key: "name")
    public var name: String

    /// 파일 바이트 그대로. 워커에게는 base64 로 실어 보낸다.
    @Field(key: "content")
    public var content: Data

    /// 이 프로필이 허용하는 권한 키. 파일에서 읽은 것이다.
    @Field(key: "entitlement_keys")
    public var entitlementKeys: [String]

    /// 만료 시각. **여기서는 적어 두기만 한다.** 지켜보는 것은 만료 감시(#89)가 한다.
    ///
    /// Apple 은 2017년 이후 Developer ID 프로필을 18년짜리로 내준다. 만료보다 먼저 오는
    /// 것은 인증서 교체다. 프로필에 든 인증서로 서명하지 않으면 macOS 가 거절한다.
    @OptionalField(key: "expires_at")
    public var expiresAt: Date?

    /// 프로필에 넣은 인증서의 ASC ID. 인증서를 갈았는지 비교하는 데 쓴다.
    @Field(key: "certificate_ids")
    public var certificateIDs: [String]

    @OptionalParent(key: "created_by")
    public var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}
}

// MARK: - 마이그레이션

public struct CreateIssuedProfile: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(IssuedProfile.schema)
            .id()
            // 앱을 지우면 프로필도 필요 없다. Apple 쪽 것은 사람이 지운다.
            .field("app_id", .uuid, .required, .references(App.schema, "id", onDelete: .cascade))
            .field("asc_profile_id", .string, .required)
            .field("name", .string, .required)
            .field("content", .data, .required)
            .field("entitlement_keys", .array(of: .string), .required)
            .field("expires_at", .datetime)
            .field("certificate_ids", .array(of: .string), .required)
            .field("created_by", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // 앱 하나에 하나. 둘이면 워커에게 무엇을 보낼지 정할 수 없다.
            .unique(on: "app_id")
            .create()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(IssuedProfile.schema).delete()
    }
}

/// 워커가 "이 권한에 프로필이 필요하다" 고 보고한 키를 버전에 둔다 (ADR-0084).
///
/// 업로더가 entitlements 를 주지 않은 앱은 서버가 그 앱의 권한을 알 길이 없다. 번들의
/// 기존 서명에 붙은 권한은 워커만 읽는다. 이 칸이 없으면 프로필을 발급할 자리가 영영
/// 나오지 않는다.
public struct AddVersionProfileEntitlements: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw(
            "ALTER TABLE versions ADD COLUMN IF NOT EXISTS profile_entitlements text[]"
        ).run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("ALTER TABLE versions DROP COLUMN IF EXISTS profile_entitlements").run()
    }
}
