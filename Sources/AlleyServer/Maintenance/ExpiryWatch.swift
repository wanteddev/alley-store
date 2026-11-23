import AlleyShared
import Fluent
import Foundation
import Vapor

/// 만료되는 것들을 지켜보다가 관리자에게 알린다 (ADR-0084).
///
/// **만료는 하나만 실패시키지 않는다.** 서명용 인증서나 멤버십이 끊기면 모든 앱의
/// 서명이 한꺼번에 멈춘다. 앱 서명 화면이 30일 전부터 빨갛게 보여주지만 그 화면을
/// 여는 사람이 있어야 보인다.
///
/// 무엇을 지켜볼지는 `ExpirySource` 가 정한다. 여기는 단계를 세고, 알리고, 알린 것을
/// 적는 일만 한다. 지켜볼 것이 늘면 `ExpirySource` 하나와 `ExpiryKind` 케이스 하나를
/// 더한다. 프로비저닝 프로필이 그렇게 붙을 예정이다.
enum ExpiryWatch {
    /// 얼마나 자주 볼지. 단계가 날 단위라 이보다 자주 볼 이유가 없다.
    static let checkInterval: Duration = .seconds(6 * 3600)

    /// 기동 뒤 첫 실행. 워커와 상관없는 작업이라 한 주기를 다 기다릴 이유가 없다. 바로
    /// 돌지 않는 것은 롤링 배포 중에 잠깐 떴다 내려가는 서버까지 Apple 에 묻지 않게
    /// 하려는 것이다.
    static let firstRunAfter: Duration = .seconds(10 * 60)

    /// 만료됐거나 날짜를 모르는 것을 다시 알리는 간격.
    ///
    /// 그 상태가 이어지는 동안은 계속 문제다. 그렇다고 쓸 때마다 알리면 하루 네 번이
    /// 되고, 그러면 아무도 안 읽는다.
    static let repeatInterval: TimeInterval = 7 * 24 * 3600

    /// 읽어오지 못하는 상태가 이만큼 이어지면 알린다.
    ///
    /// Apple 쪽 장애는 몇 시간 안에 풀리는 일이 많다. 한 번 실패했다고 알리면 그것이
    /// 소음이 되고, 정말로 키가 폐기됐을 때 묻힌다.
    static let unreadableGrace: TimeInterval = 24 * 3600

    /// `sources` 와 `notifier` 는 시험이 넣는다. Apple 과 이야기하지 않고 단계 계산과
    /// 알린 기록을 확인해야 한다.
    static func run(
        on application: Application,
        now: Date = Date(),
        sources: [any ExpirySource]? = nil,
        notifier: Notifier? = nil
    ) async {
        let database = application.db
        let logger = application.logger
        let notifier = notifier ?? Notifier(
            database: database,
            channels: application.notificationChannels,
            logger: logger
        )
        let context = Context(
            database: database,
            logger: logger,
            notifier: notifier,
            now: now,
            link: application.alleyConfig.publicBaseURL.trimmingSuffix("/") + "/admin/portal"
        )

        for source in sources ?? defaultSources(for: application) {
            let things: [ExpiringThing]
            do {
                guard let read = try await source.things(on: database) else {
                    // 지금은 볼 수 없는 상태다(연동이 꺼져 있다). 실패가 아니므로 알리지
                    // 않고, 이전 기록도 건드리지 않는다.
                    await context.clearFailure(of: source)
                    continue
                }
                things = read
            } catch {
                await context.recordFailure(of: source, error: error)
                continue
            }
            await context.clearFailure(of: source)
            await context.review(things, from: source)
        }
    }

    /// 실제로 도는 감시 대상들.
    static func defaultSources(for application: Application) -> [any ExpirySource] {
        [
            SigningCertificateSource(application: application),
            MembershipSource(),
        ]
    }
}

// MARK: - 감시 대상

/// 만료되는 것 하나.
struct ExpiringThing: Sendable, Equatable {
    /// 알린 기록을 가르는 열쇠. 대상의 `id` 로 시작해야 한다 (`ExpirySource`).
    var subject: String
    var kind: ExpiryKind
    /// 사람이 알아볼 이름. 인증서 이름 같은 것.
    var name: String?
    /// 만료 시각. 비어 있으면 모른다. 모른다는 것도 알릴 거리다.
    var expiresAt: Date?
    /// 남은 날을 날짜끼리 센다. 만료가 날짜로만 정해진 것(멤버십)에 쓴다.
    ///
    /// 시각으로 세면 0시가 아닌 때에 돌 때마다 하루가 빠진다. 그러면 화면은 "31일 남음"
    /// 인데 알림은 "30일 뒤" 가 되고, 마지막 날 알림이 하루 앞당겨진다.
    var countsByDate = false
}

/// 만료 정보를 어디서 읽어오는가.
///
/// **읽기만 한다.** 단계를 세거나 알리는 것은 `ExpiryWatch` 가 한다. 그래야 새 대상을
/// 붙일 때 "언제 몇 번 알리나" 를 다시 정하지 않는다.
protocol ExpirySource: Sendable {
    /// 실패 기록과 알린 기록을 가르는 이름. 이 대상이 내놓는 `subject` 는 모두 이것이거나
    /// `이것:` 으로 시작해야 한다. 사라진 것의 기록을 지울 때 이것으로 찾는다.
    var id: String { get }

    /// 지금 만료를 지켜볼 것들. 볼 수 없는 상태(연동이 꺼져 있다)면 nil.
    ///
    /// 던지면 읽기 실패로 친다. 실패가 `ExpiryWatch.unreadableGrace` 넘게 이어지면
    /// 아래 문구로 한 번 알린다.
    func things(on database: any Database) async throws -> [ExpiringThing]?

    /// 오래 읽지 못했을 때 보낼 말. nil 이면 알리지 않는다.
    func unreadableMessage(since: Date, reason: String, link: String) -> NotificationMessage?
}

/// 무엇이 만료되는가. 갈래마다 문구가 다르다.
///
/// 케이스를 더하면 `message` 가 컴파일을 막는다. 문구 없이 알림이 나가는 일이 없다.
enum ExpiryKind: Sendable, Equatable {
    /// 서명에 쓰는 Developer ID 인증서.
    case signingCertificate
    /// Apple Developer Program 멤버십.
    case membership

    /// 이 단계에서 보낼 말. 보낼 말이 없는 조합이면 nil.
    func message(
        for thing: ExpiringThing,
        stage: ExpiryStage,
        now: Date,
        link: String
    ) -> NotificationMessage? {
        let date = thing.expiresAt.map { DateStyle.day.string(from: $0) }
        let days = thing.expiresAt.map {
            ExpiryStage.daysLeft(until: $0, now: now, byDate: thing.countsByDate)
        } ?? 0

        switch (self, stage) {
        case (.signingCertificate, .expired):
            return NotificationMessage(
                title: "서명 인증서가 만료됐습니다",
                body: """
                    인증서: \(thing.name ?? "-")
                    만료일: \(date ?? "-")
                    워커 키체인에 새 인증서를 넣기 전까지 서명이 모두 실패합니다. 이미 바꿨다면 \
                    Apple Developer 에서 이 인증서를 폐기하세요. 남아 있는 동안 일주일마다 다시 알립니다.
                    """,
                link: link
            )
        case (.signingCertificate, .unknown):
            // 만료일이 없는 인증서는 대상이 애초에 내놓지 않는다.
            return nil
        case (.signingCertificate, _):
            return NotificationMessage(
                title: "서명 인증서가 \(days)일 뒤 만료됩니다",
                body: """
                    인증서: \(thing.name ?? "-")
                    만료일: \(date ?? "-")
                    만료되면 워커가 모든 앱에 서명하지 못합니다. Apple Developer 에서 새 \
                    Developer ID 인증서를 만들어 서명 맥 키체인에 넣으세요.
                    """,
                link: link
            )
        case (.membership, .unknown):
            return NotificationMessage(
                title: "Apple Developer Program 멤버십 만료일이 비어 있습니다",
                body: """
                    만료되면 인증서가 무효가 되고 공증도 거절되는데, 날짜를 몰라 미리 알릴 수 \
                    없습니다. 앱 서명 화면에 만료일을 적어 주세요. 적을 때까지 일주일마다 다시 알립니다.
                    """,
                link: link
            )
        case (.membership, .expired):
            return NotificationMessage(
                title: "Apple Developer Program 멤버십 만료일이 지났습니다",
                body: """
                    적어둔 만료일: \(date ?? "-")
                    갱신하지 않았다면 지금 서명과 공증이 막혀 있습니다. 갱신했다면 앱 서명 화면에서 \
                    만료일을 새 날짜로 고치세요. 고칠 때까지 일주일마다 다시 알립니다.
                    """,
                link: link
            )
        case (.membership, _):
            return NotificationMessage(
                title: "Apple Developer Program 멤버십이 \(days)일 뒤 만료됩니다",
                body: """
                    적어둔 만료일: \(date ?? "-")
                    만료되면 인증서가 무효가 되고 공증도 거절됩니다. 갱신했다면 앱 서명 화면에서 \
                    만료일을 새 날짜로 고치세요.
                    """,
                link: link
            )
        }
    }
}

// MARK: - 단계

/// 만료까지 어디쯤 왔나.
///
/// **단계마다 한 번만 알린다.** 처음 켰을 때 이미 7일 남았으면 7일 단계 한 통만 간다.
/// 30일·14일을 뒤늦게 몰아 보내면 같은 이야기가 세 번 온다.
enum ExpiryStage: String, Sendable, CaseIterable {
    /// 날짜를 모른다.
    case unknown
    case days30 = "d30"
    case days14 = "d14"
    case days7 = "d7"
    case days1 = "d1"
    case expired

    /// 알리기 시작하는 날. 앱 서명 화면이 빨갛게 바뀌는 날과 같아야 한다. 화면은
    /// 빨간데 알림은 안 온다거나 그 반대가 되면 둘 중 하나를 의심하게 된다.
    static let warnings: [(days: Int, stage: ExpiryStage)] = [
        (PortalGrouping.expiringSoonDays, .days30),
        (14, .days14),
        (7, .days7),
        (1, .days1),
    ]

    /// 지금 어느 단계인가. 아직 알릴 때가 아니면 nil.
    static func of(expiresAt: Date?, now: Date, byDate: Bool = false) -> ExpiryStage? {
        guard let expiresAt else { return .unknown }
        guard expiresAt > now else { return .expired }
        let days = daysLeft(until: expiresAt, now: now, byDate: byDate)
        return warnings.last { days <= $0.days }?.stage
    }

    /// 만료까지 남은 날. 하루가 안 남았어도 1 로 센다. "0일 뒤" 는 읽는 사람이 오늘인지
    /// 지났는지 헷갈린다.
    ///
    /// `byDate` 면 오늘 0시부터 센다. 각 화면이 세는 방식과 맞춘 것이다. 인증서 표는
    /// 지금부터 시각으로(`ASCCertificate.daysUntilExpiry`), 멤버십 칸은 날짜끼리
    /// (`MembershipExpiry.daysLeft`) 센다.
    static func daysLeft(until expiresAt: Date, now: Date, byDate: Bool = false) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let from = byDate ? calendar.startOfDay(for: now) : now
        let days = calendar.dateComponents([.day], from: from, to: expiresAt).day ?? 0
        return max(1, days)
    }

    /// 다시 알리는 단계인가. 지나가는 단계와 달리 머무르는 동안 계속 문제다.
    var repeats: Bool {
        self == .expired || self == .unknown
    }

    /// 급한 정도. 이 값이 올라갈 때만 새로 알린다.
    var urgency: Int {
        switch self {
        case .unknown: return 0
        case .days30: return 1
        case .days14: return 2
        case .days7: return 3
        case .days1: return 4
        case .expired: return 5
        }
    }
}

// MARK: - 기록

extension ExpiryWatch {
    /// 한 번 도는 동안 함께 쓰는 것들.
    struct Context {
        var database: any Database
        var logger: Logger
        var notifier: Notifier
        var now: Date
        var link: String

        /// 대상이 내놓은 것들을 보고, 알릴 것을 알리고, 사라진 것의 기록을 지운다.
        func review(_ things: [ExpiringThing], from source: any ExpirySource) async {
            let records: [ExpiryNotice]
            do {
                records = try await ExpiryNotice.query(on: database).all()
                    .filter { Self.belongs($0.subject, to: source) }
            } catch {
                logger.error("만료 감시 기록을 읽지 못했습니다 [\(source.id)]: \(error)")
                return
            }
            let bySubject = Dictionary(
                records.map { ($0.subject, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for thing in things {
                await review(thing, record: bySubject[thing.subject])
            }

            // 사라진 것은 잊는다. 폐기한 인증서의 기록이 남아 있으면, 같은 열쇠로 다시
            // 나타날 일은 없어도 표가 계속 자란다.
            let present = Set(things.map(\.subject))
            for record in records where !present.contains(record.subject) {
                try? await record.delete(on: database)
            }
        }

        private func review(_ thing: ExpiringThing, record: ExpiryNotice?) async {
            guard let stage = ExpiryStage.of(
                expiresAt: thing.expiresAt, now: now, byDate: thing.countsByDate
            ) else {
                // 아직 멀다. 갱신해서 멀어졌다면 기록을 지워 다음에 처음부터 센다.
                if let record { try? await record.delete(on: database) }
                return
            }
            guard Self.shouldNotify(stage: stage, expiresAt: thing.expiresAt, record: record, now: now)
            else { return }
            guard let message = thing.kind.message(for: thing, stage: stage, now: now, link: link)
            else { return }

            // **보낸 것만 보냈다고 적는다.** 채널도 관리자 연락 수단도 없으면 아무 데도
            // 가지 않는데, 그때 기록하면 이 단계는 다시 오지 않는다 (`UserTokenExpiryNotice`).
            guard await notifier.notifyOperators(message) else {
                logger.notice("만료 알림을 받을 곳이 없어 다음 주기에 다시 봅니다 [\(thing.subject)]")
                return
            }
            logger.notice("만료 알림을 보냈습니다 [\(thing.subject), 단계: \(stage.rawValue)]")

            let saved = record ?? ExpiryNotice(
                subject: thing.subject, expiresAt: nil, stage: stage.rawValue, notifiedAt: now
            )
            saved.expiresAt = thing.expiresAt
            saved.stage = stage.rawValue
            saved.notifiedAt = now
            do {
                try await saved.save(on: database)
            } catch {
                // 다음 주기에 또 보낸다. 두 번 오는 것이 안 오는 것보다 낫다.
                logger.error("만료 알림 기록에 실패했습니다 [\(thing.subject)]: \(error)")
            }
        }

        /// 이번에 알려야 하나.
        static func shouldNotify(
            stage: ExpiryStage,
            expiresAt: Date?,
            record: ExpiryNotice?,
            now: Date
        ) -> Bool {
            guard let record else { return true }
            // 날짜가 바뀌었으면 다른 것이다. 멤버십 만료일을 고쳐 적었거나 인증서를 다시
            // 받은 경우라 처음부터 센다.
            guard sameMoment(record.expiresAt, expiresAt) else { return true }
            let previous = ExpiryStage(rawValue: record.stage) ?? .unknown
            if stage.urgency > previous.urgency { return true }
            return stage.repeats && now.timeIntervalSince(record.notifiedAt) >= ExpiryWatch.repeatInterval
        }

        /// 데이터베이스를 거치면 초 아래 자리가 달라진다. 같은 날짜를 다르다고 보면
        /// 쓸 때마다 알린다.
        static func sameMoment(_ lhs: Date?, _ rhs: Date?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case let (left?, right?): return abs(left.timeIntervalSince(right)) < 1
            default: return false
            }
        }

        static func belongs(_ subject: String, to source: any ExpirySource) -> Bool {
            subject == source.id || subject.hasPrefix(source.id + ":")
        }

        /// 읽기 실패를 적고, 오래 이어졌으면 한 번 알린다.
        func recordFailure(of source: any ExpirySource, error: any Error) async {
            let reason = String(describing: error)
            logger.warning("만료 정보를 읽지 못했습니다 [\(source.id)]: \(reason)")

            let existing = try? await ExpirySourceFailure.query(on: database)
                .filter(\.$source == source.id)
                .first()
            let failure = existing ?? ExpirySourceFailure(
                source: source.id, failingSince: now, lastError: reason
            )
            failure.lastError = reason

            if failure.alertedAt == nil,
               now.timeIntervalSince(failure.failingSince) >= ExpiryWatch.unreadableGrace,
               let message = source.unreadableMessage(
                   since: failure.failingSince, reason: reason, link: link
               ),
               await notifier.notifyOperators(message)
            {
                failure.alertedAt = now
            }

            do {
                try await failure.save(on: database)
            } catch {
                logger.error("만료 감시 실패 기록에 실패했습니다 [\(source.id)]: \(error)")
            }
        }

        /// 다시 읽혔다. 다음 실패는 처음부터 센다.
        func clearFailure(of source: any ExpirySource) async {
            try? await ExpirySourceFailure.query(on: database)
                .filter(\.$source == source.id)
                .delete()
        }
    }
}
