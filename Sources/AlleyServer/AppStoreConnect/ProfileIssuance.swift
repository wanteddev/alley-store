import AlleyShared
import Fluent
import Foundation
import Vapor

/// 앱 하나에 Developer ID 프로비저닝 프로필을 발급하는 규칙 (ADR-0085).
///
/// **버튼 한 번에 끝까지 간다.** App ID 가 없으면 만들고, 모자란 capability 를 켜고,
/// 프로필을 만들어 보관한다. 단계를 나눠 누르게 하면 사람이 순서를 알아야 하고,
/// capability 를 켠 순간 Apple 이 기존 프로필을 무효로 만들어서 중간에 멈추면 서명이
/// 오히려 깨진다.
///
/// **사람이 누를 때만 한다.** 서명이 실패했다고 서버가 알아서 발급하지 않는다. App ID 와
/// 프로필은 Apple 계정에 남고, 지우는 것은 우리 손을 떠난다 (ADR-0053 과 같은 이유).
enum ProfileIssuance {
    struct Outcome {
        var profile: IssuedProfile
        var bundleID: String
        /// App ID 를 이번에 새로 만들었나.
        var createdAppID: Bool
        /// 이번에 켠 capability.
        var enabled: [ProfileCapability]
        /// 만든 프로필이 그래도 허용하지 않는 키. Apple 화면에서 켜야 한다.
        var stillMissing: [String]
        /// 켰지만 Apple 화면에서 더 할 일이 남은 것.
        var portalChores: [String]
        /// 키는 실렸는데 값이 비어 있는 것. iCloud 컨테이너나 판매자 ID 를 아직 연결하지
        /// 않은 경우다. 이대로 서명하면 워커의 대조에서 걸린다.
        var unlinked: [String]

        /// 사람이 Apple 화면에서 먼저 할 일이 있는가. 있으면 다시 시도해도 또 멈춘다.
        var needsPortalWork: Bool { !stillMissing.isEmpty || !unlinked.isEmpty }

        /// 발급 직후 화면 맨 위에 띄울 첫 문장. 새로고침 뒤에도 같은 말을 한다.
        static let issuedNotice = "프로비저닝 프로필을 발급했습니다. 다음 서명부터 워커가 번들에 넣습니다."

        /// 화면에 띄울 한 문단.
        var notice: String {
            var parts = [Self.issuedNotice]
            if createdAppID { parts.append("App ID 도 새로 만들었습니다.") }
            if !enabled.isEmpty {
                parts.append("켠 capability: \(enabled.map(\.displayName).joined(separator: ", ")).")
            }
            parts += portalChores
            if !stillMissing.isEmpty {
                parts.append(ProfilePlan.missingKeysAdvice(stillMissing, bundleID: bundleID))
            }
            return parts.joined(separator: " ")
        }
    }

    /// 이 앱에서 지금 프로필이 있어야 하는 권한 키. **가장 최근 버전**을 본다.
    ///
    /// 옛 버전까지 합치면, 예전에 실수로 넣었다 뺀 권한(Developer ID 가 못 쓰는 것 등)이
    /// 발급을 영영 막거나 필요 없는 capability 를 켠다. 지금 서명받으려는 것은 최근 빌드다.
    static func requiredKeys(of versions: [Version]) -> [String] {
        guard let latest = versions.max(by: { $0.buildNumber < $1.buildNumber }) else {
            return []
        }
        return requiredKeys(of: latest)
    }

    /// 버전 하나에서 프로필이 있어야 하는 권한 키.
    ///
    /// 업로더가 준 entitlements 와, 워커가 번들에서 읽고 보고한 키를 합친다. 업로더가
    /// 아무것도 주지 않은 앱은 뒤쪽이 유일한 단서다.
    static func requiredKeys(of version: Version) -> [String] {
        var keys = Set<String>(version.profileEntitlements ?? [])
        if let plist = version.entitlements {
            keys.formUnion(EntitlementsPlist.keys(of: plist))
        }
        // Developer ID 로 못 쓰는 키도 모두 `com.apple.developer.` 라 여기 함께 남는다.
        // 발급할 때 `ProfilePlan` 이 그것을 가려 막는다.
        return EntitlementsPlist.requiringProvisioningProfile(in: keys)
    }

    static func issue(
        for app: App,
        keys: [String],
        using client: AppStoreConnectClient,
        by user: User,
        on database: any Database,
        logger: Logger,
        now: Date = Date()
    ) async throws -> Outcome {
        let plan = ProfilePlan(keys: keys)
        guard plan.unsupported.isEmpty else {
            throw Abort(
                .unprocessableEntity,
                reason: """
                    이 앱은 Developer ID 로 배포하는 앱이 쓸 수 없는 권한을 씁니다: \
                    \(plan.unsupported.joined(separator: ", ")). 프로필로 풀리지 않으니 이 권한을 \
                    빼고 다시 빌드해야 합니다.
                    """
            )
        }
        guard !plan.keys.isEmpty else {
            throw Abort(
                .conflict,
                reason: "이 앱은 프로필이 필요한 권한을 쓰지 않습니다. 프로필 없이 서명됩니다."
            )
        }
        guard !app.bundleIDPending else {
            throw Abort(
                .conflict,
                reason: "번들 ID 가 아직 확정되지 않았습니다. 첫 서명이 끝나 번들 ID 가 정해진 뒤에 발급할 수 있습니다."
            )
        }

        // 1. 인증서. 살아 있는 Developer ID Application 인증서를 **전부** 넣는다.
        //    서버는 워커가 어느 것으로 서명하는지 모른다. 프로필에 없는 인증서로 서명하면
        //    macOS 가 실행할 때 거절한다.
        //    **Apple 계정을 바꾸기 전에** 본다. capability 를 켠 뒤에 여기서 멈추면 있던
        //    프로필만 무효가 되고 새 프로필은 생기지 않는다.
        let certificates = try await client.certificates().filter {
            $0.isDeveloperIDApplication && ($0.expiresAt ?? .distantFuture) > now
        }
        guard !certificates.isEmpty else {
            throw Abort(
                .conflict,
                reason: """
                    살아 있는 Developer ID Application 인증서가 Apple 계정에 없습니다. 프로필은 \
                    인증서를 넣어 만들어야 합니다. 관리 > 앱 서명에서 인증서를 확인하세요.
                    """
            )
        }

        // 2. App ID. 이미 있으면 그것을 쓴다. Xcode 가 만들어 뒀을 수 있다.
        var createdAppID = false
        let bundleID: ASCBundleID
        if let existing = try await client.bundleID(identifier: app.bundleID) {
            bundleID = existing
        } else {
            bundleID = try await client.registerBundleID(identifier: app.bundleID, name: app.name)
            createdAppID = true
            logger.notice("App ID 등록 [\(app.bundleID), 프로필 발급 중, 누른 사람: \(user.email)]")
        }

        // 3. capability. 이미 켜진 것은 건드리지 않는다.
        let present = try await client.capabilities(ofBundleID: bundleID.id)
        var enabled: [ProfileCapability] = []
        for capability in plan.capabilities where !present.contains(capability.rawValue) {
            try await client.enableCapability(capability, onBundleID: bundleID.id)
            enabled.append(capability)
        }

        // 4. 프로필. 이름이 겹치면 Apple 이 거절하므로 시각을 붙인다.
        let created = try await client.createProfile(
            name: profileName(for: app.bundleID, at: now),
            bundleIDResourceID: bundleID.id,
            certificateIDs: certificates.map(\.id)
        )
        let parsed: ProvisioningProfile?
        do {
            parsed = try ProvisioningProfile(data: created.content)
        } catch {
            // 보관은 한다. 워커는 번들에 넣고 대조할 때 다시 읽는다. 다만 무엇을 허용하는지
            // 모르니 전부 모자란 것으로 말한다. 화면의 줄과 같은 판단이다.
            parsed = nil
            logger.warning("발급한 프로필을 읽지 못했습니다 [\(created.id): \(error)]")
        }

        // 5. 보관. 앱마다 하나라 있으면 바꾼다.
        let appID = try app.requireID()
        let record = try await IssuedProfile.query(on: database)
            .filter(\.$app.$id == appID)
            .first() ?? IssuedProfile()
        let previousASCID = record.id == nil ? nil : record.ascProfileID
        record.$app.id = appID
        record.ascProfileID = created.id
        record.name = created.name
        record.content = created.content
        record.entitlementKeys = parsed?.entitlementKeys ?? []
        record.expiresAt = created.expiresAt ?? parsed?.expiresAt
        record.certificateIDs = certificates.map(\.id)
        record.$createdBy.id = try user.requireID()
        try await record.save(on: database)

        // 6. Apple 쪽 옛 것을 지운다. capability 를 켰다면 이미 무효다. 못 지워도 새 것은
        //    이미 보관했으니 실패로 다루지 않는다. 계정에 쓰레기가 하나 남을 뿐이다.
        if let previousASCID, previousASCID != created.id {
            do {
                try await client.deleteProfile(id: previousASCID)
            } catch {
                logger.warning("옛 프로필을 Apple 에서 지우지 못했습니다 [\(previousASCID): \(error)]")
            }
        }

        logger.notice(
            """
            프로필 발급 [\(app.bundleID), \(created.name), 켠 capability: \
            \(enabled.map(\.rawValue)), 누른 사람: \(user.email)]
            """
        )

        return Outcome(
            profile: record,
            bundleID: app.bundleID,
            createdAppID: createdAppID,
            enabled: enabled,
            stillMissing: parsed?.missingKeys(for: plan.keys) ?? plan.keys,
            portalChores: plan.portalChores(bundleID: app.bundleID),
            unlinked: plan.keys.filter { key in
                ProfileCapability.linkedValueKeys.contains(key)
                    && parsed?.entitlementValues[key]?.isEmpty == true
            }
        )
    }

    static func profileName(for bundleID: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Alley \(bundleID) \(formatter.string(from: date))"
    }
}

extension ASCCertificate {
    /// 앱 서명에 쓰는 Developer ID 인증서인지. 커널 확장·설치 패키지용은 뺀다.
    var isDeveloperIDApplication: Bool {
        type.uppercased().hasPrefix("DEVELOPER_ID_APPLICATION")
    }
}
