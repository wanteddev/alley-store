import AlleyShared
import Fluent
import Foundation

/// 앱 상세의 프로비저닝 프로필 구역에 그릴 것 (ADR-0085).
///
/// **누르기 전에 무엇을 할지 보여준다.** 버튼 하나가 App ID 생성, capability 켜기,
/// 프로필 생성까지 하므로, 그중 무엇이 Apple 계정을 바꾸는지와 스토어가 못 하는 것이
/// 무엇인지를 같은 계산(`ProfilePlan`)으로 미리 말한다.
struct ProfileSection: Encodable {
    /// 프로필이 있어야 하는 권한 키.
    var keys: [String]
    /// 필요하면 켤 capability 의 이름을 쉼표로 이은 것. 없으면 nil.
    var capabilities: String?
    /// 켠 뒤에도 Apple 화면에서 할 일.
    var portalChores: [String]
    /// 스토어가 무엇을 켜야 할지 모르는 키. 만든 프로필이 허용하는지로 판단한다.
    var unmapped: [String]
    /// Developer ID 로는 못 쓰는 키. 있으면 발급하지 않는다.
    var unsupported: [String]
    /// 발급해 둔 프로필. 없으면 nil.
    var issued: IssuedProfileRow?
    /// 지금 누를 수 있는가.
    var canIssue: Bool
    /// 누를 수 없다면 왜. 연동이 없는 경우는 화면이 따로 말한다.
    var blockedReason: String?

    /// 그릴 것이 없으면 nil.
    static func make(
        for app: App,
        keys: [String],
        isPortalConfigured: Bool,
        on database: any Database
    ) async throws -> ProfileSection? {
        let stored = try await IssuedProfile.query(on: database)
            .filter(\.$app.$id == app.requireID())
            .first()
        guard !keys.isEmpty || stored != nil else { return nil }

        let plan = ProfilePlan(keys: keys)
        let blockedReason = Self.blockedReason(for: app, plan: plan)

        return ProfileSection(
            keys: plan.keys,
            capabilities: plan.capabilities.isEmpty
                ? nil
                : plan.capabilities.map(\.displayName).joined(separator: ", "),
            portalChores: plan.portalChores(bundleID: app.bundleID),
            unmapped: plan.unmapped,
            unsupported: plan.unsupported,
            issued: stored.map {
                IssuedProfileRow(profile: $0, requiredKeys: plan.keys, bundleID: app.bundleID)
            },
            canIssue: isPortalConfigured && blockedReason == nil,
            blockedReason: blockedReason
        )
    }

    /// 이 권한으로는 발급할 수 없다면 왜. 연동 여부는 보지 않는다.
    static func blockedReason(for app: App, plan: ProfilePlan) -> String? {
        if !plan.unsupported.isEmpty {
            return """
                Developer ID 로 배포하는 앱은 이 권한을 쓸 수 없습니다: \
                \(plan.unsupported.joined(separator: ", ")). 프로필로 풀리지 않으니 권한을 빼고 \
                다시 빌드해야 합니다.
                """
        } else if app.bundleIDPending {
            return "번들 ID 가 확정된 뒤에 발급할 수 있습니다. 첫 서명이 끝나면 정해집니다."
        } else if plan.keys.isEmpty {
            return "지금 올린 버전들은 프로필이 필요한 권한을 쓰지 않습니다."
        }
        return nil
    }

    /// 실패한 버전 옆 "발급하고 다시 시도" 를 막는 이유. 누를 수 있으면 nil.
    ///
    /// **앱 구역이 아니라 그 버전의 권한으로 판단한다.** 앱 구역은 최신 버전을 보므로,
    /// 최신 버전이 프로필을 쓰지 않으면 지난 버전의 버튼까지 막힌다. 발급도 그 버전의
    /// 권한으로 한다(`issueProfileAndRetry`).
    static func retryBlockedReason(
        for app: App,
        version: Version,
        isPortalConfigured: Bool
    ) -> String? {
        guard isPortalConfigured else {
            return """
                App Store Connect 연동이 설정되지 않아 여기서 발급할 수 없습니다. 관리 > 앱 \
                서명 화면에 무엇을 채워야 하는지 적혀 있습니다.
                """
        }
        return blockedReason(
            for: app, plan: ProfilePlan(keys: ProfileIssuance.requiredKeys(of: version))
        )
    }
}

struct IssuedProfileRow: Encodable {
    var name: String
    var issuedAt: DisplayDate
    var expiresAt: DisplayDate?
    /// 이 프로필이 허용하지 않는데 앱이 쓰는 키가 있으면 무엇을 하라는 말. 없으면 nil.
    var missingAdvice: String?

    init(profile: IssuedProfile, requiredKeys: [String], bundleID: String) {
        self.name = profile.name
        self.issuedAt = DateStyle.day.display(from: profile.updatedAt ?? profile.createdAt ?? Date())
        self.expiresAt = profile.expiresAt.map { DateStyle.day.display(from: $0) }
        let missing = ProvisioningProfile(entitlementKeys: profile.entitlementKeys)
            .missingKeys(for: requiredKeys)
        self.missingAdvice = missing.isEmpty
            ? nil
            : ProfilePlan.missingKeysAdvice(missing, bundleID: bundleID)
    }
}
