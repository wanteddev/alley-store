import AlleyShared
import Fluent
import Foundation
import Vapor

/// App Store Connect 가 말하는 서명용 인증서들 (ADR-0084).
///
/// 앱 서명 화면이 "서명용 인증서" 로 묶는 것과 같은 기준(`isDeveloperID`)으로 고른다.
/// 화면에는 있는데 알림은 안 오는 인증서가 생기면 안 된다.
///
/// **이것은 Apple 쪽 기록이다.** 워커가 실제로 키체인에 쥐고 있는 인증서와 다를 수
/// 있다. 그 대조는 워커가 자기 인증서를 알려야 할 수 있어 따로 한다.
struct SigningCertificateSource: ExpirySource {
    let id = "certificate"

    /// 인증서 목록을 가져온다. 연동이 꺼져 있으면 nil.
    private let fetch: @Sendable () async throws -> [ASCCertificate]?

    init(fetch: @escaping @Sendable () async throws -> [ASCCertificate]?) {
        self.fetch = fetch
    }

    init(application: Application) {
        let config = application.alleyConfig.appStoreConnect
        let client = application.client
        self.init {
            guard let config else { return nil }
            return try await AppStoreConnectClient(config: config, client: client).certificates()
        }
    }

    func things(on database: any Database) async throws -> [ExpiringThing]? {
        guard let certificates = try await fetch() else { return nil }
        return certificates
            .filter(\.isDeveloperID)
            .compactMap { certificate in
                // 만료일 없는 인증서는 Apple 이 그렇게 준 것이다. 알릴 것이 없다.
                guard let expiresAt = certificate.expiresAt else { return nil }
                return ExpiringThing(
                    subject: "\(id):\(certificate.id)",
                    kind: .signingCertificate,
                    name: certificate.name,
                    expiresAt: expiresAt
                )
            }
    }

    func unreadableMessage(since: Date, reason: String, link: String) -> NotificationMessage? {
        NotificationMessage(
            title: "App Store Connect 를 하루 넘게 읽지 못했습니다",
            body: """
                실패하기 시작한 때: \(DateStyle.minute.string(from: since))
                이유: \(reason)
                그동안 인증서 만료를 감시하지 못합니다. API 키가 폐기됐거나, 멤버십이 끊겼거나, \
                Apple 이 새 약관 동의를 기다리고 있을 수 있습니다.
                """,
            link: link
        )
    }
}

/// 관리자가 적어둔 Apple Developer Program 멤버십 만료일 (ADR-0084).
///
/// 비어 있어도 하나를 내놓는다. 날짜를 모르는 것 자체를 알려야 하기 때문이다.
/// 끄는 자리는 두지 않는다. 멤버십 없이 쓰는 스토어는 없다.
struct MembershipSource: ExpirySource {
    let id = "membership"

    func things(on database: any Database) async throws -> [ExpiringThing]? {
        let settings = try await StoreSettings.find(StoreSettings.singletonID, on: database)
        return [
            ExpiringThing(
                subject: id,
                kind: .membership,
                name: nil,
                expiresAt: MembershipExpiry.date(from: settings?.membershipExpiresOn),
                countsByDate: true
            )
        ]
    }

    /// 데이터베이스를 못 읽는 것은 이 감시만의 문제가 아니다. 따로 알리지 않는다.
    func unreadableMessage(since: Date, reason: String, link: String) -> NotificationMessage? {
        nil
    }
}

/// 멤버십 만료일을 글자와 시각 사이에서 옮긴다.
///
/// 저장은 `2027-03-15` 같은 날짜 글자로 한다(`StoreSettings.membershipExpiresOn`).
/// 감시와 화면은 그 날 0시(서버 타임존)를 만료 시각으로 본다. 그날 끝까지 쓸 수 있을지
/// 모르는 것을 늦게 알리는 것보다 하루 일찍 알리는 쪽이 낫다.
enum MembershipExpiry {
    /// 날짜 칸이 보내는 형식. `<input type="date">` 가 언제나 이렇게 보낸다.
    static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text),
              formatter.string(from: date) == text
        else { return nil }
        return date
    }

    /// 폼에서 온 값을 저장할 꼴로 고친다. 비었으면 nil, 읽을 수 없으면 던진다.
    static func normalized(_ input: String?) throws -> String? {
        let trimmed = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard date(from: trimmed) != nil else {
            throw Abort(.badRequest, reason: "만료일을 읽지 못했습니다. YYYY-MM-DD 형식으로 적으세요.")
        }
        return trimmed
    }

    /// 오늘부터 만료일까지 남은 날. 날짜끼리 센다. 지났으면 음수.
    static func daysLeft(until text: String?, now: Date = Date()) -> Int? {
        guard let expiry = date(from: text) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: today, to: expiry).day
    }
}
