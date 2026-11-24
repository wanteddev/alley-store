import AlleyShared
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 정해 둔 것을 내놓는 감시 대상. Apple 과 이야기하지 않고 단계와 기록을 본다.
private final class StubSource: ExpirySource, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var result: Result<[ExpiringThing]?, any Error>

    init(id: String = "certificate", things: [ExpiringThing]? = []) {
        self.id = id
        self.result = .success(things)
    }

    struct Down: Error, CustomStringConvertible {
        var description: String { "App Store Connect 가 403 를 돌려줬습니다: FORBIDDEN_ERROR" }
    }

    func set(_ things: [ExpiringThing]?) {
        lock.lock()
        defer { lock.unlock() }
        result = .success(things)
    }

    func fail() {
        lock.lock()
        defer { lock.unlock() }
        result = .failure(Down())
    }

    private func current() -> Result<[ExpiringThing]?, any Error> {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func things(on database: any Database) async throws -> [ExpiringThing]? {
        try current().get()
    }

    func unreadableMessage(since: Date, reason: String, link: String) -> NotificationMessage? {
        NotificationMessage(title: "읽지 못했습니다", body: reason, link: link)
    }
}

private let day: TimeInterval = 24 * 3600

private func certificate(_ id: String = "C1", expiresAt: Date?) -> ExpiringThing {
    ExpiringThing(
        subject: "certificate:\(id)",
        kind: .signingCertificate,
        name: "Developer ID Application: Example Corp (ABCDE12345)",
        expiresAt: expiresAt
    )
}

@Suite("만료 단계")
struct ExpiryStageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(
        "남은 날로 단계를 고른다",
        arguments: [
            (31.0, nil),
            (30.5, ExpiryStage.days30),
            (20.0, .days30),
            (14.2, .days14),
            (5.0, .days7),
            (1.5, .days1),
            (0.2, .days1),
            (-0.1, .expired),
        ] as [(Double, ExpiryStage?)]
    )
    func stageByDaysLeft(daysLeft: Double, expected: ExpiryStage?) {
        let expiresAt = now.addingTimeInterval(daysLeft * day)
        #expect(ExpiryStage.of(expiresAt: expiresAt, now: now) == expected)
    }

    @Test("날짜를 모르면 그것도 단계다")
    func unknownDate() {
        #expect(ExpiryStage.of(expiresAt: nil, now: now) == .unknown)
    }

    /// 화면은 빨간데 알림은 안 온다거나 그 반대가 되면 둘 중 하나를 의심하게 된다.
    @Test("알리기 시작하는 날은 화면이 빨개지는 날과 같다")
    func firstWarningMatchesScreen() {
        #expect(ExpiryStage.warnings.first?.days == PortalGrouping.expiringSoonDays)
        let thirty = ASCCertificate(
            id: "C1", name: "Developer ID", type: "DEVELOPER_ID_APPLICATION",
            expiresAt: Date().addingTimeInterval(30.5 * day)
        )
        #expect(CertificateRow(certificate: thirty).needsAttention)
    }

    /// 화면은 "31일 남음" 인데 알림은 "30일 뒤" 면 둘 중 하나를 의심하게 된다.
    @Test("멤버십은 화면과 같이 날짜끼리 세어 단계를 고른다")
    func membershipCountsByDate() throws {
        let morning = try #require(MembershipExpiry.date(from: "2027-02-13")).addingTimeInterval(10 * 3600)
        let expiry = try #require(MembershipExpiry.date(from: "2027-03-15"))
        let screen = MembershipRow(expiresOn: "2027-03-15", now: morning)

        #expect(screen.daysLeft == 30)
        #expect(screen.needsAttention)
        #expect(ExpiryStage.daysLeft(until: expiry, now: morning, byDate: true) == 30)
        #expect(ExpiryStage.of(expiresAt: expiry, now: morning, byDate: true) == .days30)

        // 하루 전 날 아침이 1일 단계다. 시각으로 세면 이틀 전에 1일 단계가 왔다.
        let dayBefore = try #require(MembershipExpiry.date(from: "2027-03-14")).addingTimeInterval(10 * 3600)
        let twoBefore = try #require(MembershipExpiry.date(from: "2027-03-13")).addingTimeInterval(10 * 3600)
        #expect(ExpiryStage.of(expiresAt: expiry, now: dayBefore, byDate: true) == .days1)
        #expect(ExpiryStage.of(expiresAt: expiry, now: twoBefore, byDate: true) == .days7)
    }

    /// "0일 뒤" 는 오늘인지 지났는지 헷갈린다.
    @Test("하루가 안 남았어도 1일로 센다")
    func lessThanADayIsOne() {
        #expect(ExpiryStage.daysLeft(until: now.addingTimeInterval(3600), now: now) == 1)
    }
}

@Suite("멤버십 만료일")
struct MembershipExpiryTests {
    @Test("날짜 칸이 보내는 형식을 받는다")
    func acceptsDateInput() throws {
        #expect(try MembershipExpiry.normalized("2027-03-15") == "2027-03-15")
        #expect(try MembershipExpiry.normalized("  ") == nil)
        #expect(try MembershipExpiry.normalized(nil) == nil)
    }

    @Test("없는 날짜나 다른 형식은 거절한다", arguments: ["2027-02-30", "2027/03/15", "다음 달", "2027-3-5"])
    func rejectsOthers(_ input: String) {
        #expect(throws: (any Error).self) { try MembershipExpiry.normalized(input) }
    }

    @Test("화면은 날짜끼리 세고, 당일부터 지난 것으로 본다")
    func rowCountsDays() throws {
        let now = try #require(MembershipExpiry.date(from: "2027-03-01"))
            .addingTimeInterval(15 * 3600)

        let far = MembershipRow(expiresOn: "2027-06-01", now: now)
        #expect(far.daysLeft == 92)
        #expect(!far.needsAttention)
        #expect(!far.isExpired)

        let near = MembershipRow(expiresOn: "2027-03-15", now: now)
        #expect(near.daysLeft == 14)
        #expect(near.needsAttention)

        let today = MembershipRow(expiresOn: "2027-03-01", now: now)
        #expect(today.isExpired)

        let empty = MembershipRow(expiresOn: nil, now: now)
        #expect(empty.daysLeft == nil)
        #expect(!empty.needsAttention)
    }
}

@Suite("만료 감시")
struct ExpiryWatchTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// 관리자 한 명이 Slack DM 으로 받는 스토어. 운영 알림 기본값이 개별 전송이다.
    private func setUp(_ app: Application) async throws -> (RecordingChannel, Notifier) {
        _ = try await app.makeUser(email: "admin@example.com", role: .admin)
        let dm = RecordingChannel(kind: .slackDirectMessage)
        return (dm, Notifier(database: app.db, channels: [dm], logger: app.logger))
    }

    @Test("단계마다 한 번만 알린다")
    func oncePerStage() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            let source = StubSource(things: [certificate(expiresAt: start.addingTimeInterval(20.5 * day))])

            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)
            #expect(dm.messages.map(\.title) == ["서명 인증서가 20일 뒤 만료됩니다"])
            #expect(dm.messages.first?.link == "https://store.example.com/admin/portal")

            // 같은 단계에서는 다시 보내지 않는다. 6시간마다 돌기 때문이다.
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(0.25 * day), sources: [source], notifier: notifier)
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(5 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.count == 1)

            // 14일 단계에 들어서면 한 번 더.
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(7 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.map(\.title).last == "서명 인증서가 13일 뒤 만료됩니다")
            #expect(dm.messages.count == 2)
        }
    }

    /// 30일·14일을 뒤늦게 몰아 보내면 같은 이야기가 세 번 온다.
    @Test("처음 볼 때 이미 가까우면 지금 단계 한 통만 간다")
    func lateStartSendsOne() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            let source = StubSource(things: [certificate(expiresAt: start.addingTimeInterval(5.5 * day))])

            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)

            #expect(dm.messages.count == 1)
            let record = try await ExpiryNotice.query(on: app.db).first()
            #expect(record?.stage == ExpiryStage.days7.rawValue)
        }
    }

    @Test("만료된 뒤에는 남아 있는 동안 일주일마다 다시 알린다")
    func expiredRepeatsWeekly() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            let source = StubSource(things: [certificate(expiresAt: start.addingTimeInterval(-day))])

            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)
            #expect(dm.messages.map(\.title) == ["서명 인증서가 만료됐습니다"])

            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(6 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.count == 1)

            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(7 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.count == 2)
        }
    }

    @Test("갱신해서 멀어지면 기록을 지우고 처음부터 센다")
    func renewalResets() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            let source = StubSource(things: [certificate(expiresAt: start.addingTimeInterval(3 * day))])
            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)
            #expect(try await ExpiryNotice.query(on: app.db).count() == 1)

            source.set([certificate(expiresAt: start.addingTimeInterval(365 * day))])
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(day), sources: [source], notifier: notifier)
            #expect(try await ExpiryNotice.query(on: app.db).count() == 0)
            #expect(dm.messages.count == 1)
        }
    }

    /// 날짜를 고쳐 적었으면 다른 것이다. 같은 단계라도 새 날짜로 한 번 알린다.
    @Test("만료 시각이 바뀌면 같은 단계라도 다시 알린다")
    func changedDateNotifiesAgain() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            let source = StubSource(things: [certificate(expiresAt: start.addingTimeInterval(20.5 * day))])
            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)

            source.set([certificate(expiresAt: start.addingTimeInterval(25.5 * day))])
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(0.25 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.count == 2)
        }
    }

    @Test("사라진 인증서의 기록은 지운다")
    func forgetsRemoved() async throws {
        try await withMigratedApp { app in
            let (_, notifier) = try await setUp(app)
            let source = StubSource(things: [
                certificate("C1", expiresAt: start.addingTimeInterval(3 * day)),
                certificate("C2", expiresAt: start.addingTimeInterval(4 * day)),
            ])
            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)
            #expect(try await ExpiryNotice.query(on: app.db).count() == 2)

            source.set([certificate("C2", expiresAt: start.addingTimeInterval(4 * day))])
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(day), sources: [source], notifier: notifier)
            let left = try await ExpiryNotice.query(on: app.db).all().map(\.subject)
            #expect(left == ["certificate:C2"])
        }
    }

    /// 보낸 적 없는데 보냈다고 적으면 그 단계는 다시 오지 않는다.
    @Test("닿을 곳이 없으면 기록하지 않고 다음에 다시 본다")
    func undeliveredIsNotRecorded() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let source = StubSource(things: [certificate(expiresAt: start.addingTimeInterval(3 * day))])

            let nowhere = Notifier(database: app.db, channels: [], logger: app.logger)
            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: nowhere)
            #expect(try await ExpiryNotice.query(on: app.db).count() == 0)

            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [dm], logger: app.logger)
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(0.25 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.count == 1)
        }
    }

    @Test("못 읽는 상태가 하루를 넘기면 한 번 알리고, 다시 읽히면 잊는다")
    func unreadableAfterADay() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            let source = StubSource()
            source.fail()

            // Apple 쪽 장애는 몇 시간 안에 풀리는 일이 많다. 바로 알리지 않는다.
            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(0.75 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.isEmpty)

            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(1.25 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.map(\.title) == ["읽지 못했습니다"])
            #expect(dm.messages.first?.body?.contains("403") == true)

            // 이어지는 동안 또 알리지 않는다.
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(3 * day), sources: [source], notifier: notifier)
            #expect(dm.messages.count == 1)

            source.set([])
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(4 * day), sources: [source], notifier: notifier)
            #expect(try await ExpirySourceFailure.query(on: app.db).count() == 0)
        }
    }

    @Test("연동이 꺼져 있으면 실패로 치지 않는다")
    func notConfiguredIsQuiet() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            let source = StubSource(things: nil)

            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(2 * day), sources: [source], notifier: notifier)

            #expect(dm.messages.isEmpty)
            #expect(try await ExpirySourceFailure.query(on: app.db).count() == 0)
        }
    }

    @Test("ASC 인증서 중 서명용만 지켜본다")
    func certificateSourcePicksDeveloperID() async throws {
        let source = SigningCertificateSource {
            [
                ASCCertificate(id: "A", name: "Developer ID", type: "DEVELOPER_ID_APPLICATION_G2",
                               expiresAt: Date()),
                ASCCertificate(id: "B", name: "Apple Development", type: "DEVELOPMENT",
                               expiresAt: Date()),
                ASCCertificate(id: "C", name: "날짜 없음", type: "DEVELOPER_ID_APPLICATION",
                               expiresAt: nil),
            ]
        }
        try await withConfiguredApp { app in
            let things = try await source.things(on: app.db)
            #expect(things?.map(\.subject) == ["certificate:A"])
        }
    }

    @Test("멤버십 만료일이 비어 있으면 적을 때까지 일주일마다 알린다")
    func emptyMembershipNags() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            _ = try await StoreSettings.loadOrSeed(
                on: app.db, seed: app.alleyConfig.store.seed, logger: app.logger
            )

            await ExpiryWatch.run(on: app, now: start, sources: [MembershipSource()], notifier: notifier)
            #expect(dm.messages.map(\.title) == ["Apple Developer Program 멤버십 만료일이 비어 있습니다"])

            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(3 * day), sources: [MembershipSource()], notifier: notifier)
            #expect(dm.messages.count == 1)
            await ExpiryWatch.run(on: app, now: start.addingTimeInterval(7 * day), sources: [MembershipSource()], notifier: notifier)
            #expect(dm.messages.count == 2)
        }
    }

    @Test("멤버십 만료일을 적으면 그 날짜로 단계를 센다")
    func membershipDateCounts() async throws {
        try await withMigratedApp { app in
            let (dm, notifier) = try await setUp(app)
            let settings = try await StoreSettings.loadOrSeed(
                on: app.db, seed: app.alleyConfig.store.seed, logger: app.logger
            )
            let now = try #require(MembershipExpiry.date(from: "2027-03-01")).addingTimeInterval(9 * 3600)
            settings.membershipExpiresOn = "2027-03-15"
            try await settings.save(on: app.db)

            await ExpiryWatch.run(on: app, now: now, sources: [MembershipSource()], notifier: notifier)
            // 화면과 같이 날짜끼리 센다. 3월 1일 아침에 3월 15일은 14일 뒤다.
            #expect(dm.messages.map(\.title) == ["Apple Developer Program 멤버십이 14일 뒤 만료됩니다"])
            #expect(dm.messages.first?.body?.contains("2027. 3. 15.") == true)

            settings.membershipExpiresOn = "2028-03-15"
            try await settings.save(on: app.db)
            await ExpiryWatch.run(on: app, now: now.addingTimeInterval(day), sources: [MembershipSource()], notifier: notifier)
            #expect(dm.messages.count == 1)
            #expect(try await ExpiryNotice.query(on: app.db).count() == 0)
        }
    }

    /// 채널을 골랐으면 채널로만 간다. 만료 알림도 운영 알림이다.
    @Test("운영 알림 설정을 따라 채널로 간다")
    func followsOperationalAlerts() async throws {
        try await withMigratedApp { app in
            _ = try await app.makeUser(email: "admin@example.com", role: .admin)
            let settings = try await StoreSettings.loadOrSeed(
                on: app.db, seed: app.alleyConfig.store.seed, logger: app.logger
            )
            settings.operationalAlerts = .channel
            try await settings.save(on: app.db)
            try await NotificationTarget(
                appID: nil, kind: .slack, name: "운영 채널",
                endpoint: "https://hooks.slack.com/services/x", createdByID: nil
            ).save(on: app.db)

            let webhook = RecordingChannel(kind: .slack)
            let dm = RecordingChannel(kind: .slackDirectMessage)
            let notifier = Notifier(database: app.db, channels: [webhook, dm], logger: app.logger)
            let source = StubSource(things: [certificate(expiresAt: start.addingTimeInterval(3 * day))])

            await ExpiryWatch.run(on: app, now: start, sources: [source], notifier: notifier)

            #expect(webhook.messages.count == 1)
            #expect(dm.messages.isEmpty)
            #expect(try await ExpiryNotice.query(on: app.db).count() == 1)
        }
    }
}

@Suite("앱 서명 화면의 멤버십 칸")
struct MembershipFormTests {
    private func save(
        _ value: String,
        token: String,
        on app: Application,
        check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.testing().test(
            .POST, "/admin/portal/membership",
            headers: .form(cookie: token),
            beforeRequest: { request in
                try request.content.encode(["membershipExpiresOn": value], as: .urlEncodedForm)
            },
            afterResponse: check
        )
    }

    @Test("적으면 저장하고 화면에 남은 날과 함께 보인다")
    func savesAndShows() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)

            try await save("2099-03-15", token: token, on: app) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers.first(name: .location) == "/admin/portal?saved=membership")
            }
            let stored = try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            #expect(stored?.membershipExpiresOn == "2099-03-15")

            try await app.testing().test(
                .GET, "/admin/portal?saved=membership", headers: .sessionCookie(token)
            ) { response in
                let body = response.body.string
                #expect(response.status == .ok)
                #expect(body.contains("멤버십 만료일을 저장했습니다."))
                #expect(body.contains("value=\"2099-03-15\""))
                #expect(body.contains("일 남음"))
                #expect(!body.contains("멤버십 만료일을 적지 않았습니다."))
            }
        }
    }

    @Test("비우면 지우고, 비어 있다고 보여준다")
    func clearing() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            try await save("2099-03-15", token: token, on: app) { _ in }
            try await save("", token: token, on: app) { #expect($0.status == .seeOther) }

            let stored = try await StoreSettings.find(StoreSettings.singletonID, on: app.db)
            #expect(stored?.membershipExpiresOn == nil)

            // 연동이 꺼져 있어도 이 칸은 그린다. App Store Connect 와 상관이 없다.
            try await app.testing().test(.GET, "/admin/portal", headers: .sessionCookie(token)) { response in
                #expect(response.body.string.contains("멤버십 만료일을 적지 않았습니다."))
                #expect(response.body.string.contains("ASC_ISSUER_ID"))
            }
        }
    }

    @Test("읽을 수 없는 날짜는 거절하고 이유를 보여준다")
    func rejectsBadDate() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "admin@example.com", role: .admin)
            try await save("2027-02-30", token: token, on: app) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("만료일을 읽지 못했습니다"))
            }
        }
    }

    @Test("관리자가 아니면 적을 수 없다")
    func adminsOnly() async throws {
        try await withMigratedApp { app in
            let (_, token) = try await app.makeUser(email: "dev@example.com", role: .developer)
            try await save("2099-03-15", token: token, on: app) { #expect($0.status == .forbidden) }
        }
    }
}
