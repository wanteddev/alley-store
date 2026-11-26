import AlleyShared
import Fluent
import Foundation
import SQLKit
import Vapor

/// 다운로드 집계.
///
/// **신규 설치와 업데이트를 나눠 센다** (ADR-0086). 한 숫자로 세면 자동 업데이트가
/// 켜진 앱은 버전을 낼 때마다 숫자가 같이 올라가서, 새로 쓰기 시작한 사람이 늘었는지
/// 기존 사용자가 업데이트를 받았을 뿐인지 알 수 없다.
///
/// **"설치"라고 부르지만 서버가 설치를 본 것은 아니다.** 서버가 아는 것은 누군가 파일을
/// 받아갔다는 사실까지다. 같은 사람이 그 앱을 처음 받은 것을 신규 설치로 센다
/// (`Download.Kind`). 실제로 깔았는지, 지금도 쓰는지는 모른다.
///
/// 집계는 SQL 로 한다. Fluent 로 전부 읽어와 Swift 에서 세면 다운로드가 쌓일수록
/// 메모리와 시간이 같이 는다.
enum DownloadStats {
    /// 신규 설치와 업데이트 수.
    struct Counts: Sendable, Equatable {
        var installs: Int = 0
        var updates: Int = 0

        /// 받아간 횟수 전부.
        var total: Int { installs + updates }
    }

    /// 앱 하나의 다운로드 요약.
    struct AppSummary: Sendable {
        var all: Counts
        /// 최근 30일.
        var recent: Counts
    }

    /// 최근 며칠을 "최근"으로 볼지.
    static let recentDays = 30

    /// `kind` 로 갈라 세는 SQL 조각. `where` 가 있으면 그 조건을 함께 건다.
    private static func counted(_ alias: String, prefix: String, where condition: String? = nil) -> SQLQueryString {
        let extra = condition.map { " AND \($0)" } ?? ""
        return """
            COUNT(\(unsafeRaw: alias).id) FILTER (WHERE \(unsafeRaw: alias).kind = 'install'\(unsafeRaw: extra)) AS \(unsafeRaw: prefix)installs,
            COUNT(\(unsafeRaw: alias).id) FILTER (WHERE \(unsafeRaw: alias).kind = 'update'\(unsafeRaw: extra)) AS \(unsafeRaw: prefix)updates
            """
    }

    private static func recentCondition(_ alias: String) -> String {
        "\(alias).created_at > now() - INTERVAL '\(recentDays) days'"
    }

    private static func decode(_ row: any SQLRow, prefix: String = "") -> Counts {
        Counts(
            installs: (try? row.decode(column: "\(prefix)installs", as: Int.self)) ?? 0,
            updates: (try? row.decode(column: "\(prefix)updates", as: Int.self)) ?? 0
        )
    }

    static func summary(
        ofApp appID: UUID,
        on database: any Database
    ) async throws -> AppSummary {
        guard let sql = database as? any SQLDatabase else {
            return AppSummary(all: Counts(), recent: Counts())
        }

        let row = try await sql.raw(
            """
            SELECT
                \(counted("d", prefix: "")),
                \(counted("d", prefix: "recent_", where: recentCondition("d")))
              FROM downloads d
              JOIN versions v ON v.id = d.version_id
             WHERE v.app_id = \(bind: appID)
            """
        ).first()

        guard let row else { return AppSummary(all: Counts(), recent: Counts()) }
        return AppSummary(all: decode(row), recent: decode(row, prefix: "recent_"))
    }

    /// 앱 여럿의 다운로드 수를 한 번에 센다. 목록 API 가 쓴다.
    ///
    /// 앱마다 `summary` 를 부르면 목록이 앱 수만큼 쿼리를 돈다.
    static func totals(
        ofApps appIDs: [UUID],
        on database: any Database
    ) async throws -> [UUID: Counts] {
        guard !appIDs.isEmpty, let sql = database as? any SQLDatabase else { return [:] }
        let rows = try await sql.raw(
            """
            SELECT v.app_id AS app_id, \(counted("d", prefix: ""))
              FROM downloads d
              JOIN versions v ON v.id = d.version_id
             WHERE v.app_id IN (\(binds: appIDs))
             GROUP BY v.app_id
            """
        ).all()
        return rows.reduce(into: [:]) { result, row in
            guard let id = try? row.decode(column: "app_id", as: UUID.self) else { return }
            result[id] = decode(row)
        }
    }

    /// 앱 하나의 버전별 다운로드 수.
    static func perVersion(
        ofApp appID: UUID,
        on database: any Database
    ) async throws -> [UUID: Counts] {
        guard let sql = database as? any SQLDatabase else { return [:] }

        let rows = try await sql.raw(
            """
            SELECT d.version_id AS version_id, \(counted("d", prefix: ""))
              FROM downloads d
              JOIN versions v ON v.id = d.version_id
             WHERE v.app_id = \(bind: appID)
             GROUP BY d.version_id
            """
        ).all()

        return rows.reduce(into: [:]) { result, row in
            guard let id = try? row.decode(column: "version_id", as: UUID.self) else { return }
            result[id] = decode(row)
        }
    }

    /// 스토어 전체 현황. 관리자 화면이 쓴다.
    struct StoreOverview: Sendable {
        struct Row: Sendable {
            var appID: UUID
            var appName: String
            var bundleID: String
            var all: Counts
            var recent: Counts
        }

        var rows: [Row]
        var all: Counts
        var recent: Counts
        /// 한 번이라도 무언가를 받아간 사람 수. 받은 사람을 모르는 줄은 세지 않는다.
        var activePeople: Int
    }

    static func overview(on database: any Database) async throws -> StoreOverview {
        guard let sql = database as? any SQLDatabase else {
            return StoreOverview(rows: [], all: Counts(), recent: Counts(), activePeople: 0)
        }

        // 다운로드가 없는 앱도 0 으로 나와야 한다. 목록에서 사라지면 "아무도 안 받는
        // 앱"이 보이지 않고, 그게 가장 알고 싶은 것 중 하나다.
        //
        // 신규 설치가 많은 순으로 늘어놓는다. 받아간 횟수 전부로 늘어놓으면 자동
        // 업데이트가 켜진 앱이 버전을 낼 때마다 위로 올라온다.
        let rows = try await sql.raw(
            """
            SELECT
                a.id AS app_id,
                a.name AS app_name,
                a.bundle_id AS bundle_id,
                \(counted("d", prefix: "")),
                \(counted("d", prefix: "recent_", where: recentCondition("d")))
              FROM apps a
              LEFT JOIN versions v ON v.app_id = a.id
              LEFT JOIN downloads d ON d.version_id = v.id
             GROUP BY a.id, a.name, a.bundle_id
             ORDER BY installs DESC, a.name
            """
        ).all()

        let parsed: [StoreOverview.Row] = rows.compactMap { row in
            guard let id = try? row.decode(column: "app_id", as: UUID.self),
                  let name = try? row.decode(column: "app_name", as: String.self),
                  let bundleID = try? row.decode(column: "bundle_id", as: String.self)
            else {
                return nil
            }
            return StoreOverview.Row(
                appID: id,
                appName: name,
                bundleID: bundleID,
                all: decode(row),
                recent: decode(row, prefix: "recent_")
            )
        }

        let totals = try await sql.raw(
            """
            SELECT
                \(counted("d", prefix: "")),
                \(counted("d", prefix: "recent_", where: recentCondition("d"))),
                COUNT(DISTINCT d.user_id) AS people
              FROM downloads d
            """
        ).first()

        return StoreOverview(
            rows: parsed,
            all: totals.map { decode($0) } ?? Counts(),
            recent: totals.map { decode($0, prefix: "recent_") } ?? Counts(),
            activePeople: (try? totals?.decode(column: "people", as: Int.self)) ?? 0
        )
    }
}
