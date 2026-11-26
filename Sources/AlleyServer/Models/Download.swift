import Fluent
import Foundation
import SQLKit
import Vapor

/// 누가 어느 버전을 언제 받아갔는지.
///
/// MVP 수용 기준에 들어 있는 항목이다. 다운로드 URL 을 내주기 **전에** 남긴다.
/// 나중에 남기면 URL 만 받고 이력이 빠지는 경로가 생긴다.
///
/// **받은 사람을 모를 수 있다.** 스토어 앱을 받는 공개 페이지는 로그인을 요구하지
/// 않는다 (ADR-0049). 거기로 받은 줄은 `user` 가 비어 있다. 이력을 아예 남기지
/// 않는 쪽도 있었지만, 그러면 "몇 번 나갔나" 까지 같이 사라진다. 사람을 모르는
/// 것과 받아간 사실을 모르는 것은 다르다.
public final class Download: Model, @unchecked Sendable {
    public static let schema = "downloads"

    @ID(key: .id)
    public var id: UUID?

    /// 받아간 사람. 공개 페이지로 받았으면 비어 있다.
    @OptionalParent(key: "user_id")
    public var user: User?

    @Parent(key: "version_id")
    public var version: Version

    /// 신규 설치인가 업데이트인가 (ADR-0086). 받을 때 서버가 정해 적는다.
    @Field(key: "kind")
    public var kind: Kind

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    /// 받아간 기록의 두 갈래 (ADR-0086).
    ///
    /// **"설치"라고 부르지만 서버가 설치를 본 것은 아니다.** 같은 사람이 그 앱을 처음
    /// 받은 것을 신규 설치, 그 뒤로 받은 것을 업데이트로 센다. 다른 맥에 다시 깔아도
    /// 업데이트다. 이 숫자가 답하려는 것은 "이 앱을 새로 쓰기 시작한 사람이 늘었나" 라서
    /// 기기가 아니라 사람으로 가른다.
    public enum Kind: String, Codable, Sendable {
        case install
        case update
    }

    public init() {}

    public init(id: UUID? = nil, userID: UUID?, versionID: UUID, kind: Kind) {
        self.id = id
        self.$user.id = userID
        self.$version.id = versionID
        self.kind = kind
    }

    /// 받아간 기록을 남긴다. 갈래는 이 사람이 같은 앱을 전에 받은 적이 있는지로 정한다.
    ///
    /// 받는 자리 셋(스토어 앱 API, 웹 콘솔, `/get`)이 모두 이것을 부른다. 자리마다
    /// 따로 가르면 같은 숫자의 뜻이 경로마다 달라진다.
    ///
    /// **받은 사람을 모르면 신규 설치다.** 로그인 없이 받는 자리는 `/get` 하나이고,
    /// 거기 오는 사람은 스토어 앱을 처음 까는 사람이다. 이미 쓰는 사람은 스토어 앱이
    /// 로그인한 채로 스스로 업데이트한다.
    ///
    /// `alreadyInstalled` 는 받는 쪽에 그 앱이 이미 깔려 있는 것이 확실할 때 준다. 스토어
    /// 앱이 API 로 자기 자신을 받는 경우가 그렇다. 그 API 를 부른 것이 스토어 앱이다.
    /// 이 사람이 처음에 `/get` 에서 익명으로 받았으면 서버는 그 줄이 이 사람 것인 줄
    /// 모르므로, 기록만 보고 가르면 같은 사람이 신규 설치로 두 번 잡힌다.
    @discardableResult
    static func record(
        userID: UUID?,
        version: Version,
        alreadyInstalled: Bool = false,
        on database: any Database
    ) async throws -> Download {
        let versionID = try version.requireID()
        var kind = Kind.install
        if alreadyInstalled {
            kind = .update
        } else if let userID {
            let earlier = try await Download.query(on: database)
                .join(Version.self, on: \Download.$version.$id == \Version.$id)
                .filter(\.$user.$id == userID)
                .filter(Version.self, \.$app.$id == version.$app.id)
                .first()
            if earlier != nil { kind = .update }
        }
        let download = Download(userID: userID, versionID: versionID, kind: kind)
        try await download.save(on: database)
        return download
    }
}

// MARK: - 마이그레이션

public struct CreateDownload: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(Download.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id"))
            // 다운로드 이력은 감사 기록이다. 버전을 지운다고 조용히 사라지면 안 된다.
            // 받아간 사람이 있는 버전은 삭제 자체가 막히는 편이 맞다.
            .field("version_id", .uuid, .required, .references(Version.schema, "id"))
            .field("created_at", .datetime)
            .create()

        // 통계 화면(Phase 4)이 version_id 로 집계하기 시작하면 인덱스를 붙인다.
        // Fluent 의 스키마 빌더에는 인덱스 API 가 없어서 별도 마이그레이션이 필요하고,
        // 지금 데이터 규모에서는 이득이 없다.
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(Download.schema).delete()
    }
}

/// 받은 사람을 모를 수 있게 한다 (ADR-0049).
///
/// 스토어 앱을 받는 공개 페이지에는 세션이 없다. `user_id` 가 `NOT NULL` 이면 그
/// 다운로드는 이력을 남길 자리가 아예 없다.
///
/// **집계는 손대지 않아도 된다.** "몇 명이 받았나" 는 `COUNT(DISTINCT user_id)` 로
/// 세는데 PostgreSQL 의 집계 함수는 NULL 을 빼고 센다. 익명 줄이 사람 수를 부풀리지
/// 않는다. "몇 번 나갔나" 는 `COUNT(*)` 라 그대로 늘어난다. 둘 다 원하는 대로다.
/// Fluent 의 스키마 빌더에는 `NOT NULL` 을 떼는 방법이 없어서 SQL 을 직접 쓴다.
/// 이 레포가 이미 여러 자리에서 쓰는 길이다 (`AddIssuerToUser`, `SigningJob`).
public struct MakeDownloadUserOptional: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("ALTER TABLE downloads ALTER COLUMN user_id DROP NOT NULL").run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        // **익명 줄을 지우고 되돌린다.** `NOT NULL` 을 다시 걸려면 그 줄들이 없어야
        // 한다. 감사 기록을 버리는 일이라 조용히 하지 않고 로그로 남긴다. 되돌릴
        // 일이 생겼다는 것은 공개 페이지를 접었다는 뜻이고, 그때 그 줄들은 가리킬
        // 사람이 없는 기록이다.
        let removed = try await Download.query(on: database).filter(\.$user.$id == nil).count()
        if removed > 0 {
            database.logger.warning("익명 다운로드 이력 \(removed)건을 지우고 되돌립니다.")
            try await Download.query(on: database).filter(\.$user.$id == nil).delete()
        }
        try await sql.raw("ALTER TABLE downloads ALTER COLUMN user_id SET NOT NULL").run()
    }
}

/// 받아간 기록을 신규 설치와 업데이트로 가른다 (ADR-0086).
///
/// **지난 기록도 같은 규칙으로 채운다.** 사람과 앱마다 가장 이른 줄이 신규 설치, 나머지가
/// 업데이트다. 받을 때 가르는 규칙(`Download.record`)과 같아야 배포 전후 기간을 견줄 수
/// 있다. 같은 시각이면 `id` 로 가른다. 어느 쪽이든 하나만 신규 설치가 되면 된다.
/// 받은 사람을 모르는 줄은 모두 신규 설치다.
///
/// **기본값을 `install` 로 둔다.** 이 마이그레이션이 끝난 뒤 새 서버가 뜨기까지 예전
/// 서버가 `kind` 없이 줄을 넣는다 (ADR-0028 의 롤링 업데이트). 기본값이 없으면 그 사이
/// 받기가 실패한다. 업데이트 몇 건을 신규 설치로 잘못 세는 편이 받기가 막히는 것보다 낫다.
///
/// 갈래를 정하려고 받을 때마다 같은 사람의 줄을 찾는다. 그 질의를 위해 `user_id`
/// 인덱스를 함께 붙인다.
public struct AddDownloadKind: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("ALTER TABLE downloads ADD COLUMN kind TEXT NOT NULL DEFAULT 'install'").run()
        try await sql.raw(
            """
            UPDATE downloads d SET kind = 'update'
              FROM (
                SELECT d2.id, ROW_NUMBER() OVER (
                    PARTITION BY d2.user_id, v.app_id ORDER BY d2.created_at, d2.id
                  ) AS n
                  FROM downloads d2 JOIN versions v ON v.id = d2.version_id
                 WHERE d2.user_id IS NOT NULL
              ) ranked
             WHERE ranked.id = d.id AND ranked.n > 1
            """
        ).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS downloads_user_idx ON downloads (user_id)").run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.needsSQLDatabase
        }
        try await sql.raw("DROP INDEX IF EXISTS downloads_user_idx").run()
        try await sql.raw("ALTER TABLE downloads DROP COLUMN kind").run()
    }
}
