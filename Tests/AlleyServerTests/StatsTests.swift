import AlleyShared
import Fluent
import Foundation
import SQLKit
import Testing
import VaporTesting

@testable import AlleyServer

/// 다운로드가 있는 앱 하나.
private struct StatsSetup {
    var owner: User
    var ownerToken: String
    var appID: UUID
    var versionID: UUID
}

private func seedDownloads(on app: Application, people: Int, times: Int) async throws -> StatsSetup {
    let (owner, ownerToken) = try await app.makeUser(email: "dev@example.com", role: .developer)
    let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
    let appID = try record.requireID()
    let version = try await app.seedVersion(
        appID: appID, short: "1.0.0", build: 1, state: .released, by: owner
    )
    let versionID = try version.requireID()

    for index in 0..<people {
        let (user, _) = try await app.makeUser(email: "user\(index)@example.com", role: .user)
        for _ in 0..<times {
            try await Download.record(userID: try user.requireID(), version: version, on: app.db)
        }
    }

    return StatsSetup(owner: owner, ownerToken: ownerToken, appID: appID, versionID: versionID)
}

@Suite("다운로드 집계")
struct DownloadStatsTests {
    @Test("신규 설치와 업데이트를 나눠 센다")
    func countsInstallsAndUpdates() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 3, times: 2)

            let summary = try await DownloadStats.summary(ofApp: setup.appID, on: app.db)
            // 사람마다 처음 받은 것이 신규 설치, 두 번째부터 업데이트다.
            #expect(summary.all == DownloadStats.Counts(installs: 3, updates: 3))
            #expect(summary.all.total == 6)
            #expect(summary.recent == DownloadStats.Counts(installs: 3, updates: 3))
        }
    }

    @Test("오래된 다운로드는 최근에서 빠진다")
    func excludesOldFromRecent() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 1, times: 1)
            let old = Download(
                userID: try setup.owner.requireID(),
                versionID: setup.versionID,
                kind: .install
            )
            try await old.save(on: app.db)
            // 저장 후에 시각을 되돌린다. @Timestamp 가 생성 시각을 덮어쓰기 때문이다.
            old.createdAt = Date().addingTimeInterval(-60 * 24 * 60 * 60)
            try await old.save(on: app.db)

            let summary = try await DownloadStats.summary(ofApp: setup.appID, on: app.db)
            #expect(summary.all.total == 2)
            #expect(summary.recent == DownloadStats.Counts(installs: 1, updates: 0))
        }
    }

    @Test("버전별로 나눠 센다")
    func countsPerVersion() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 2, times: 1)
            let second = try await app.seedVersion(
                appID: setup.appID, short: "1.1.0", build: 2, state: .released, by: setup.owner
            )
            // 소유자는 처음 받아 신규 설치, 다시 받아 업데이트다.
            for _ in 0..<2 {
                try await Download.record(userID: try setup.owner.requireID(), version: second, on: app.db)
            }

            let counts = try await DownloadStats.perVersion(ofApp: setup.appID, on: app.db)
            #expect(counts[setup.versionID] == DownloadStats.Counts(installs: 2, updates: 0))
            #expect(counts[try second.requireID()] == DownloadStats.Counts(installs: 1, updates: 1))
        }
    }

    @Test("다운로드가 없는 앱도 목록에 남는다")
    func keepsAppsWithoutDownloads() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 1, times: 1)
            _ = try await app.seedApp(
                bundleID: "com.example.quiet", name: "아무도 안 받는 앱", owner: setup.owner
            )

            // 목록에서 사라지면 그 사실을 알 수 없다. 그게 가장 알고 싶은 것 중 하나다.
            let overview = try await DownloadStats.overview(on: app.db)
            #expect(overview.rows.count == 2)
            #expect(overview.rows.contains { $0.appName == "아무도 안 받는 앱" && $0.all.total == 0 })
        }
    }

    @Test("전체 합계를 낸다")
    func totalsAcrossApps() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 2, times: 2)
            let other = try await app.seedApp(
                bundleID: "com.example.other", name: "다른 앱", owner: setup.owner
            )
            let version = try await app.seedVersion(
                appID: try other.requireID(), short: "1.0.0", build: 1,
                state: .released, by: setup.owner
            )
            try await Download.record(userID: try setup.owner.requireID(), version: version, on: app.db)

            let overview = try await DownloadStats.overview(on: app.db)
            #expect(overview.all == DownloadStats.Counts(installs: 3, updates: 2))
            // 앱 둘을 받은 사람이 있어도 사람은 한 번만 센다.
            #expect(overview.activePeople == 3)
            // 신규 설치가 많은 앱이 먼저다.
            #expect(overview.rows.map(\.appName) == ["도구", "다른 앱"])
        }
    }
}

@Suite("통계 화면")
struct StatsPageTests {
    @Test("관리자가 아니면 볼 수 없다")
    func requiresAdmin() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await app.testing().test(
                .GET, "/admin/stats", headers: .sessionCookie(token)
            ) { #expect($0.status == .forbidden) }
        }
    }

    @Test("앱별 숫자를 보여준다")
    func showsPerAppNumbers() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 2, times: 3)
            _ = setup
            let (_, adminToken) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await app.testing().test(
                .GET, "/admin/stats", headers: .sessionCookie(adminToken)
            ) { response in
                #expect(response.status == .ok)
                let html = response.body.string
                #expect(html.contains("도구"))
                // 두 사람이 세 번씩: 신규 설치 둘, 업데이트 넷.
                #expect(html.contains(">2<"))
                #expect(html.contains(">4<"))
                // 서버가 설치를 본 것이 아니라는 것과 무엇을 신규 설치로 세는지 적는다.
                #expect(html.contains("실제로 설치했는지"))
                #expect(html.contains("처음 받은 것을 신규 설치"))
            }
        }
    }

    @Test("앱 상세에는 올릴 수 있는 사람에게만 보인다")
    func detailNumbersAreForUploaders() async throws {
        try await withMigratedApp { app in
            let setup = try await seedDownloads(on: app, people: 1, times: 1)
            let (_, readerToken) = try await app.makeUser(
                email: "reader@example.com", role: .user
            )
            let path = "/apps/\(setup.appID.uuidString)"

            try await app.testing().test(
                .GET, path, headers: .sessionCookie(setup.ownerToken)
            ) { #expect($0.body.string.contains("최근 30일 신규 설치")) }

            // 받는 사람에게는 쓸 데가 없는 숫자다.
            try await app.testing().test(
                .GET, path, headers: .sessionCookie(readerToken)
            ) { #expect(!$0.body.string.contains("최근 30일 신규 설치")) }
        }
    }
}

@Suite("신규 설치와 업데이트 가르기")
struct DownloadKindTests {
    @Test("같은 사람이 같은 앱을 다시 받으면 업데이트다")
    func judgesByPerson() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (reader, _) = try await app.makeUser(email: "reader@example.com", role: .user)
            let tool = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let first = try await app.seedVersion(appID: try tool.requireID(), short: "1.0", build: 1, state: .released, by: owner)
            let second = try await app.seedVersion(appID: try tool.requireID(), short: "1.1", build: 2, state: .released, by: owner)
            let memo = try await app.seedApp(bundleID: "com.example.memo", name: "메모장", owner: owner)
            let memoVersion = try await app.seedVersion(appID: try memo.requireID(), short: "1.0", build: 1, state: .released, by: owner)
            let readerID = try reader.requireID()

            // 처음 받으면 신규 설치다.
            #expect(try await Download.record(userID: readerID, version: first, on: app.db).kind == .install)
            // 다른 버전이어도 같은 앱을 전에 받았으면 업데이트다.
            #expect(try await Download.record(userID: readerID, version: second, on: app.db).kind == .update)
            // 같은 버전을 다시 받아도 업데이트다. 다른 맥에 다시 까는 것도 사람으로 센다.
            #expect(try await Download.record(userID: readerID, version: second, on: app.db).kind == .update)
            // 다른 앱은 따로 센다.
            #expect(try await Download.record(userID: readerID, version: memoVersion, on: app.db).kind == .install)
            // 다른 사람은 따로 센다.
            #expect(try await Download.record(userID: try owner.requireID(), version: second, on: app.db).kind == .install)
        }
    }

    /// 로그인 없이 받는 자리는 `/get` 하나이고, 거기 오는 사람은 스토어 앱을 처음 깐다.
    @Test("받은 사람을 모르면 신규 설치다")
    func anonymousIsInstall() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(bundleID: "com.example.store", name: "스토어", owner: owner)
            let version = try await app.seedVersion(appID: try record.requireID(), short: "1.0", build: 1, state: .released, by: owner)

            for _ in 0..<2 {
                #expect(try await Download.record(userID: nil, version: version, on: app.db).kind == .install)
            }
        }
    }

    /// 배포 전 기록도 받을 때와 같은 규칙으로 갈라야 배포 전후 기간을 견줄 수 있다.
    @Test("지난 기록은 사람과 앱마다 가장 이른 것만 신규 설치로 채운다")
    func backfillsExistingRows() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (reader, _) = try await app.makeUser(email: "reader@example.com", role: .user)
            let tool = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let first = try await app.seedVersion(appID: try tool.requireID(), short: "1.0", build: 1, state: .released, by: owner)
            let second = try await app.seedVersion(appID: try tool.requireID(), short: "1.1", build: 2, state: .released, by: owner)
            let memo = try await app.seedApp(bundleID: "com.example.memo", name: "메모장", owner: owner)
            let memoVersion = try await app.seedVersion(appID: try memo.requireID(), short: "1.0", build: 1, state: .released, by: owner)

            // 칸이 생기기 전으로 돌려 예전 서버가 남긴 줄을 흉내 낸다.
            try await AddDownloadKind().revert(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            func insert(_ userID: UUID?, _ version: Version, day: Int) async throws -> UUID {
                let id = UUID()
                try await sql.raw(
                    """
                    INSERT INTO downloads (id, user_id, version_id, created_at)
                    VALUES (\(bind: id), \(bind: userID), \(bind: try version.requireID()), \(bind: Date(timeIntervalSince1970: Double(day) * 86_400)))
                    """
                ).run()
                return id
            }
            let readerID = try reader.requireID()
            // 넣는 순서와 시각을 어긋나게 둔다. 시각으로 가려야 한다.
            let later = try await insert(readerID, second, day: 3)
            let earliest = try await insert(readerID, first, day: 1)
            let again = try await insert(readerID, first, day: 2)
            let otherApp = try await insert(readerID, memoVersion, day: 4)
            let anonymous = [try await insert(nil, first, day: 5), try await insert(nil, first, day: 6)]

            try await AddDownloadKind().prepare(on: app.db)

            let kinds = Dictionary(
                uniqueKeysWithValues: try await Download.query(on: app.db).all().map { (try $0.requireID(), $0.kind) }
            )
            #expect(kinds[earliest] == .install)
            #expect(kinds[again] == .update)
            #expect(kinds[later] == .update)
            #expect(kinds[otherApp] == .install)
            #expect(anonymous.map { kinds[$0] } == [.install, .install])
        }
    }
}
