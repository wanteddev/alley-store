import AlleyShared
import Crypto
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import AlleyServer

/// 무엇을 켤지 정하는 계산 (ADR-0085). 화면이 미리 말하는 것과 버튼이 실제로 하는
/// 것이 이 하나에서 나온다.
@Suite("프로필 발급 계획")
struct ProfilePlanTests {
    @Test("권한 키에서 켤 capability 를 고른다")
    func mapsKeysToCapabilities() {
        let plan = ProfilePlan(keys: [
            "com.apple.developer.icloud-services",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.aps-environment",
            "com.apple.security.cs.allow-jit",
        ])

        // 같은 capability 를 부르는 키가 여럿이어도 한 번만 켠다.
        #expect(plan.capabilities == [.iCloud, .pushNotifications])
        // 하드닝 권한은 프로필과 상관없다.
        #expect(!plan.keys.contains("com.apple.security.cs.allow-jit"))
        #expect(plan.unmapped.isEmpty)
    }

    @Test("모든 프로필에 실리는 키는 켤 것이 없다")
    func implicitKeysNeedNoCapability() {
        let plan = ProfilePlan(keys: [
            "keychain-access-groups",
            "com.apple.application-identifier",
        ])
        #expect(plan.capabilities.isEmpty)
        #expect(plan.implicit.count == 2)
        #expect(plan.unmapped.isEmpty)
    }

    @Test("대응표에 없는 키는 따로 모은다")
    func collectsUnmappedKeys() {
        // WeatherKit 은 Developer ID 가 못 쓴다. 대응표에 없는 예로 다른 것을 쓴다.
        let plan = ProfilePlan(keys: ["com.apple.developer.usernotifications.time-sensitive"])
        #expect(plan.unmapped == ["com.apple.developer.usernotifications.time-sensitive"])
    }

    @Test("Developer ID 로 못 쓰는 키를 가려 둔다")
    func flagsUnsupportedKeys() {
        let plan = ProfilePlan(keys: ["com.apple.developer.applesignin"])
        #expect(plan.unsupported == ["com.apple.developer.applesignin"])
        #expect(plan.keys.isEmpty)
    }

    @Test("Apple 화면에서 할 일은 어느 화면에서 무엇을 하는지까지 말한다")
    func portalChoresAreComplete() throws {
        let plan = ProfilePlan(keys: ["com.apple.developer.icloud-container-identifiers"])
        let chore = try #require(plan.portalChores(bundleID: "com.example.tool").first)
        #expect(chore.contains("Identifiers"))
        #expect(chore.contains("com.example.tool"))
        #expect(chore.contains("프로필 다시 발급"))
    }
}

@Suite("프로필 발급")
struct ProfileIssuanceTests {
    private let cloudKit = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict><key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array></dict>
        </plist>
        """

    private func seed(on app: Application) async throws -> (App, User) {
        let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
        let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
        let version = try await app.seedVersion(
            appID: try record.requireID(), short: "1.0.0", build: 1, state: .failed, by: owner
        )
        version.entitlements = cloudKit
        try await version.save(on: app.db)
        return (record, owner)
    }

    private func client(_ fake: FakeAppleAPI) -> AppStoreConnectClient {
        AppStoreConnectClient(
            config: .init(
                issuerID: "issuer", keyID: "KEY123",
                privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation
            ),
            client: fake
        )
    }

    @Test("App ID 를 만들고 capability 를 켜고 프로필을 보관한다")
    func issuesFromScratch() async throws {
        try await withMigratedApp { app in
            let (record, owner) = try await seed(on: app)
            let fake = FakeAppleAPI()

            let outcome = try await ProfileIssuance.issue(
                for: record,
                keys: ["com.apple.developer.icloud-services"],
                using: client(fake),
                by: owner,
                on: app.db,
                logger: app.logger
            )

            #expect(outcome.createdAppID)
            #expect(outcome.enabled == [.iCloud])
            #expect(outcome.stillMissing.isEmpty)

            // iCloud 는 버전을 골라 켜야 한다. CloudKit 을 쓰려면 XCODE_6 이다.
            let capability = try #require(fake.body(of: .POST, "/v1/bundleIdCapabilities"))
            #expect(capability.contains("\"capabilityType\":\"ICLOUD\""))
            #expect(capability.contains("XCODE_6"))

            // 서명용 인증서만 넣는다. 개발용 인증서를 넣어도 해는 없지만 Apple 이 거절할 수 있다.
            let profileRequest = try #require(fake.body(of: .POST, "/v1/profiles"))
            #expect(profileRequest.contains("MAC_APP_DIRECT"))
            #expect(profileRequest.contains("\"cert-devid\""))
            #expect(!profileRequest.contains("\"cert-dev\""))
            #expect(!profileRequest.contains("\"cert-expired\""))

            let stored = try #require(
                try await IssuedProfile.query(on: app.db)
                    .filter(\.$app.$id == record.requireID()).first()
            )
            #expect(stored.ascProfileID == "profile-1")
            #expect(stored.entitlementKeys.contains("com.apple.developer.icloud-services"))
            #expect(stored.certificateIDs == ["cert-devid"])
            #expect(stored.expiresAt != nil)
        }
    }

    @Test("이미 있는 App ID 와 capability 는 건드리지 않는다")
    func reusesExistingAppIDAndCapabilities() async throws {
        try await withMigratedApp { app in
            let (record, owner) = try await seed(on: app)
            let fake = FakeAppleAPI(existingBundleID: true, enabledCapabilities: ["ICLOUD"])

            let outcome = try await ProfileIssuance.issue(
                for: record,
                keys: ["com.apple.developer.icloud-services"],
                using: client(fake),
                by: owner,
                on: app.db,
                logger: app.logger
            )

            #expect(!outcome.createdAppID)
            #expect(outcome.enabled.isEmpty)
            #expect(fake.body(of: .POST, "/v1/bundleIds") == nil)
            #expect(fake.body(of: .POST, "/v1/bundleIdCapabilities") == nil)
        }
    }

    /// 프로필은 고칠 수 없어서 다시 만든다. 옛 것을 Apple 에 남기면 계정에 쌓이고,
    /// capability 를 켰다면 이미 무효다.
    @Test("다시 발급하면 행을 바꾸고 Apple 쪽 옛 프로필을 지운다")
    func reissueReplacesAndDeletesOld() async throws {
        try await withMigratedApp { app in
            let (record, owner) = try await seed(on: app)
            let fake = FakeAppleAPI(existingBundleID: true, enabledCapabilities: ["ICLOUD"])

            for _ in 0..<2 {
                _ = try await ProfileIssuance.issue(
                    for: record,
                    keys: ["com.apple.developer.icloud-services"],
                    using: client(fake),
                    by: owner,
                    on: app.db,
                    logger: app.logger
                )
            }

            let rows = try await IssuedProfile.query(on: app.db).all()
            #expect(rows.count == 1)
            #expect(rows.first?.ascProfileID == "profile-2")
            #expect(fake.requested(.DELETE, "/v1/profiles/profile-1"))
        }
    }

    @Test("만든 프로필이 허용하지 않는 키를 알려준다")
    func reportsKeysTheProfileStillLacks() async throws {
        try await withMigratedApp { app in
            let (record, owner) = try await seed(on: app)
            // Apple 이 그 capability 를 켜 주지 않은 경우다. 대응표에 없는 키가 그렇다.
            let fake = FakeAppleAPI(profileAllows: ["com.apple.developer.icloud-services"])

            let outcome = try await ProfileIssuance.issue(
                for: record,
                keys: [
                    "com.apple.developer.icloud-services",
                    "com.apple.developer.usernotifications.time-sensitive",
                ],
                using: client(fake),
                by: owner,
                on: app.db,
                logger: app.logger
            )

            #expect(outcome.stillMissing == ["com.apple.developer.usernotifications.time-sensitive"])
            #expect(outcome.notice.contains("Identifiers"))
        }
    }

    @Test("컨테이너를 연결하지 않은 프로필은 사람이 할 일이 남은 것으로 본다")
    func flagsUnlinkedContainers() async throws {
        try await withMigratedApp { app in
            let (record, owner) = try await seed(on: app)
            let fake = FakeAppleAPI(emptyContainers: true)

            let outcome = try await ProfileIssuance.issue(
                for: record,
                keys: ["com.apple.developer.icloud-container-identifiers"],
                using: client(fake),
                by: owner,
                on: app.db,
                logger: app.logger
            )

            #expect(outcome.unlinked == ["com.apple.developer.icloud-container-identifiers"])
            #expect(outcome.needsPortalWork)
        }
    }

    /// 예전에 넣었다 뺀 권한이 지금 발급을 막으면 안 된다.
    @Test("가장 최근 버전의 권한만 본다")
    func looksAtLatestVersionOnly() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let old = try await app.seedVersion(
                appID: try record.requireID(), short: "1.0.0", build: 1, state: .failed, by: owner
            )
            old.profileEntitlements = ["com.apple.developer.applesignin"]
            try await old.save(on: app.db)
            let latest = try await app.seedVersion(
                appID: try record.requireID(), short: "1.1.0", build: 2, state: .failed, by: owner
            )
            latest.profileEntitlements = ["com.apple.developer.icloud-services"]
            try await latest.save(on: app.db)

            #expect(ProfileIssuance.requiredKeys(of: [old, latest]) == ["com.apple.developer.icloud-services"])
        }
    }

    @Test("Developer ID 로 못 쓰는 권한이 있으면 Apple 에 아무것도 만들지 않는다")
    func refusesUnsupportedKeys() async throws {
        try await withMigratedApp { app in
            let (record, owner) = try await seed(on: app)
            let fake = FakeAppleAPI()

            await #expect(throws: (any Error).self) {
                _ = try await ProfileIssuance.issue(
                    for: record,
                    keys: ["com.apple.developer.applesignin"],
                    using: client(fake),
                    by: owner,
                    on: app.db,
                    logger: app.logger
                )
            }
            #expect(fake.requests.isEmpty)
        }
    }

    /// capability 를 켜는 순간 Apple 은 있던 프로필을 무효로 만든다. 그 뒤에 인증서가
    /// 없어 멈추면 새 프로필 없이 옛 프로필만 잃는다.
    @Test("살아 있는 인증서가 없으면 Apple 계정을 바꾸기 전에 멈춘다")
    func checksCertificatesBeforeChangingAccount() async throws {
        try await withMigratedApp { app in
            let (record, owner) = try await seed(on: app)
            let fake = FakeAppleAPI(noLiveCertificates: true)

            await #expect(throws: (any Error).self) {
                _ = try await ProfileIssuance.issue(
                    for: record,
                    keys: ["com.apple.developer.icloud-services"],
                    using: client(fake),
                    by: owner,
                    on: app.db,
                    logger: app.logger
                )
            }
            #expect(fake.requested(.GET, "/v1/certificates"))
            #expect(!fake.requested(.POST, "/v1/bundleIds"))
            #expect(!fake.requested(.POST, "/v1/bundleIdCapabilities"))
            #expect(!fake.requested(.POST, "/v1/profiles"))
        }
    }

    @Test("키 역할이 모자라면 무엇을 확인할지 말한다")
    func explainsForbidden() async throws {
        try await withMigratedApp { app in
            let (record, owner) = try await seed(on: app)
            let fake = FakeAppleAPI(forbidsWrites: true)

            do {
                _ = try await ProfileIssuance.issue(
                    for: record,
                    keys: ["com.apple.developer.icloud-services"],
                    using: client(fake),
                    by: owner,
                    on: app.db,
                    logger: app.logger
                )
                Issue.record("막혀야 한다")
            } catch let error as AppStoreConnectClient.ClientError {
                guard case .forbidden = error else {
                    Issue.record("403 은 역할 문제로 말해야 한다: \(error)")
                    return
                }
                #expect(error.description.contains("Admin"))
                #expect(error.description.contains("팀 키"))
            }
        }
    }
}

/// 워커와 화면 사이의 연결 (ADR-0085).
@Suite("프로필과 서명 잡")
struct ProfileSigningFlowTests {
    private var nextJobPath: String { "\(APIPath.nextJob)?timeout=0" }

    @Test("발급해 둔 프로필을 지시서에 실어 보낸다")
    func ticketCarriesProfile() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let version = try await app.seedVersion(
                appID: try record.requireID(), short: "1.0.0", build: 1, state: .uploaded, by: owner
            )
            let content = FakeProfile.make(allowing: ["com.apple.developer.icloud-services"])
            let profile = IssuedProfile()
            profile.$app.id = try record.requireID()
            profile.ascProfileID = "profile-1"
            profile.name = "Alley com.example.tool"
            profile.content = content
            profile.entitlementKeys = ["com.apple.developer.icloud-services"]
            profile.certificateIDs = ["cert-devid"]
            try await profile.save(on: app.db)
            try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)

            let (_, token) = try await app.makeWorker()
            try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) { response in
                let ticket = try response.content.decode(SigningJobDTO.self)
                #expect(ticket.provisioningProfile == content.base64EncodedString())
            }
        }
    }

    @Test("프로필이 없으면 지시서에 싣지 않는다")
    func ticketWithoutProfile() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let version = try await app.seedVersion(
                appID: try record.requireID(), short: "1.0.0", build: 1, state: .uploaded, by: owner
            )
            try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)

            let (_, token) = try await app.makeWorker()
            try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) { response in
                let ticket = try response.content.decode(SigningJobDTO.self)
                #expect(ticket.provisioningProfile == nil)
            }
        }
    }

    /// 업로더가 entitlements 를 주지 않은 앱은 서버가 권한을 모른다. 워커의 보고가 없으면
    /// 프로필을 발급할 자리가 영영 나오지 않는다.
    @Test("워커가 보고한 권한으로 앱 상세에 발급 자리가 선다")
    func workerReportOpensTheSection() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (owner, ownerCookie) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (member, memberCookie) = try await app.makeUser(email: "member@example.com", role: .developer)
            let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let appID = try record.requireID()
            try await AppMember(appID: appID, userID: try member.requireID()).save(on: app.db)
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .uploaded, by: owner
            )
            try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)

            let (_, token) = try await app.makeWorker()
            var claimed: SigningJobDTO?
            try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) {
                claimed = try $0.content.decode(SigningJobDTO.self)
            }
            let ticket = try #require(claimed)

            try await app.testing().test(
                .PATCH, APIPath.job(ticket.id),
                headers: .bearer(token),
                beforeRequest: {
                    try $0.content.encode(
                        SigningJobUpdate(
                            state: .failed,
                            failureReason: "프로필이 없습니다.",
                            failureCode: .provisioningProfileRequired,
                            profileEntitlements: ["com.apple.developer.icloud-services"]
                        )
                    )
                }
            ) { #expect($0.status == .noContent) }

            let stored = try #require(try await Version.find(try version.requireID(), on: app.db))
            #expect(stored.profileEntitlements == ["com.apple.developer.icloud-services"])

            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(ownerCookie)
            ) { response in
                let body = response.body.string
                #expect(body.contains("프로비저닝 프로필"))
                #expect(body.contains("com.apple.developer.icloud-services"))
                #expect(body.contains("프로비저닝 프로필 필요"))
            }

            // 업로드 멤버는 실패와 안내는 보지만 발급 구역은 못 본다. Apple 계정을 바꾸는 일이다.
            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(memberCookie)
            ) { response in
                let body = response.body.string
                #expect(body.contains("프로비저닝 프로필 필요"))
                #expect(!body.contains("id=\"provisioning-profile\""))
                #expect(!body.contains("/issue-profile"))
            }
        }
    }

    /// 워커가 잡을 가져가 프로필 때문에 실패했다고 보고한 상태를 만든다.
    private func failForProfile(
        _ version: Version,
        on app: Application,
        bundleMetadata: BundleMetadata? = nil
    ) async throws {
        try await SigningJob.enqueue(versionID: try version.requireID(), on: app.db)
        let (_, token) = try await app.makeWorker()
        var claimed: SigningJobDTO?
        try await app.testing().test(.GET, nextJobPath, headers: .bearer(token)) {
            claimed = try $0.content.decode(SigningJobDTO.self)
        }
        let ticket = try #require(claimed)
        try await app.testing().test(
            .PATCH, APIPath.job(ticket.id),
            headers: .bearer(token),
            beforeRequest: {
                try $0.content.encode(
                    SigningJobUpdate(
                        state: .failed,
                        failureReason: "프로필이 없습니다.",
                        failureCode: .provisioningProfileRequired,
                        bundleMetadata: bundleMetadata,
                        profileEntitlements: ["com.apple.developer.icloud-services"]
                    )
                )
            }
        ) { #expect($0.status == .noContent) }
    }

    /// 임시 번들 ID 는 서명이 끝나야 확정되는데 프로필은 확정된 번들 ID 로만 발급된다.
    /// 프로필 실패에서 확정하지 않으면 둘이 서로를 기다린다.
    @Test("번들 ID 가 임시값인 앱은 프로필 실패에서 번들 ID 를 확정한다")
    func profileFailureConfirmsPendingBundleID() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(
                bundleID: AppRegistration.provisionalBundleID(), name: "도구", owner: owner
            )
            record.bundleIDPending = true
            try await record.save(on: app.db)
            let version = try await app.seedVersion(
                appID: try record.requireID(), short: "1.0.0", build: 1, state: .uploaded, by: owner
            )

            try await failForProfile(
                version, on: app,
                bundleMetadata: BundleMetadata(bundleIdentifier: "com.example.fromdmg")
            )

            let stored = try #require(try await App.find(try record.requireID(), on: app.db))
            #expect(stored.bundleID == "com.example.fromdmg")
            #expect(stored.bundleIDPending == false)
            let storedVersion = try #require(try await Version.find(try version.requireID(), on: app.db))
            #expect(storedVersion.state == .failed)
        }
    }

    /// 앱 구역은 최신 버전의 권한을 본다. 버전 옆 버튼까지 그것을 따르면 최신 버전이
    /// 프로필을 쓰지 않을 때 지난 실패 버전은 발급할 길이 없어진다.
    @Test("지난 실패 버전의 발급 버튼은 그 버전의 권한으로 판단한다")
    func retryButtonFollowsItsOwnVersion() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (owner, cookie) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let appID = try record.requireID()
            let failed = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .uploaded, by: owner
            )
            try await failForProfile(failed, on: app)
            // 그 뒤에 프로필이 필요 없는 버전이 올라왔다.
            try await app.seedVersion(appID: appID, short: "1.0.1", build: 2, state: .ready, by: owner)
            let action = "/apps/\(appID)/versions/\(try failed.requireID())/issue-profile"

            // 연동이 없으면 숨기지 않고 누를 수 없게 둔 뒤 이유를 적는다.
            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(cookie)
            ) { response in
                let body = response.body.string
                #expect(body.contains(action))
                #expect(body.contains("disabled>프로필 발급하고 다시 시도"))
                #expect(body.contains("App Store Connect 연동이 설정되지 않아 여기서 발급할 수 없습니다"))
            }

            app.alleyConfig.appStoreConnect = .init(
                issuerID: "issuer", keyID: "KEY123",
                privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation
            )
            try await app.testing().test(
                .GET, "/apps/\(appID)", headers: .sessionCookie(cookie)
            ) { response in
                let body = response.body.string
                #expect(body.contains(action))
                #expect(body.contains("type=\"submit\">프로필 발급하고 다시 시도"))
            }
        }
    }

    /// 최신 버전이 프로필을 쓰지 않으면 프로필 구역이 없다. 지난 실패 버전에서 발급하다
    /// 막혔을 때 그 이유를 구역 안에만 두면 보이지 않는다.
    @Test("프로필 구역이 없어도 발급이 막힌 이유를 보인다")
    func showsIssueErrorWithoutSection() async throws {
        try await withMigratedApp { app in
            app.useFakeStorage()
            let (owner, cookie) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let appID = try record.requireID()
            let failed = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .uploaded, by: owner
            )
            try await failForProfile(failed, on: app)
            try await app.seedVersion(appID: appID, short: "1.0.1", build: 2, state: .ready, by: owner)

            // 시험 환경에는 연동이 없어 발급이 막힌다. 그 이유가 화면에 남아야 한다.
            try await app.testing().test(
                .POST, "/apps/\(appID)/versions/\(try failed.requireID())/issue-profile",
                headers: .form(cookie: cookie)
            ) { response in
                let body = response.body.string
                #expect(!body.contains("<section class=\"section\" id=\"provisioning-profile\">"))
                #expect(body.contains("App Store Connect 연동이 설정되지 않았습니다"))
            }
        }
    }

    @Test("발급하고 다시 시도는 앱을 관리하는 사람만 누른다")
    func issueAndRetryRequiresManageAccess() async throws {
        try await withMigratedApp { app in
            let (owner, _) = try await app.makeUser(email: "dev@example.com", role: .developer)
            let (member, memberCookie) = try await app.makeUser(email: "member@example.com", role: .developer)
            let record = try await app.seedApp(bundleID: "com.example.tool", name: "도구", owner: owner)
            let appID = try record.requireID()
            try await AppMember(appID: appID, userID: try member.requireID()).save(on: app.db)
            let version = try await app.seedVersion(
                appID: appID, short: "1.0.0", build: 1, state: .failed, by: owner
            )

            try await app.testing().test(
                .POST, "/apps/\(appID)/versions/\(try version.requireID())/issue-profile",
                headers: .form(cookie: memberCookie)
            ) { #expect($0.status == .forbidden) }
        }
    }
}

// MARK: - 가짜 App Store Connect

/// 요청을 기록하고 정해 둔 답을 주는 App Store Connect.
///
/// JSON:API 모양만 흉내 낸다. 우리가 보내는 본문이 Apple 이 요구하는 모양인지와,
/// 발급 순서가 맞는지를 보는 것이 목적이다.
final class FakeAppleAPI: Client, @unchecked Sendable {
    struct Recorded {
        var method: HTTPMethod
        var path: String
        var body: String?
    }

    private let state = NIOLockedValueBox<[Recorded]>([])
    private let profileCounter = NIOLockedValueBox(0)
    private let existingBundleID: Bool
    private let enabledCapabilities: [String]
    private let profileAllows: [String]?
    private let forbidsWrites: Bool
    private let emptyContainers: Bool
    private let noLiveCertificates: Bool

    init(
        existingBundleID: Bool = false,
        enabledCapabilities: [String] = [],
        profileAllows: [String]? = nil,
        forbidsWrites: Bool = false,
        emptyContainers: Bool = false,
        noLiveCertificates: Bool = false
    ) {
        self.noLiveCertificates = noLiveCertificates
        self.emptyContainers = emptyContainers
        self.existingBundleID = existingBundleID
        self.enabledCapabilities = enabledCapabilities
        self.profileAllows = profileAllows
        self.forbidsWrites = forbidsWrites
    }

    var requests: [Recorded] { state.withLockedValue { $0 } }

    func body(of method: HTTPMethod, _ path: String) -> String? {
        requests.first { $0.method == method && $0.path == path }?.body
    }

    func requested(_ method: HTTPMethod, _ path: String) -> Bool {
        requests.contains { $0.method == method && $0.path == path }
    }

    var eventLoop: any EventLoop { EmbeddedEventLoop() }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let path = request.url.path
        let body = request.body.map { String(buffer: $0) }
        state.withLockedValue { $0.append(.init(method: request.method, path: path, body: body)) }
        return eventLoop.makeSucceededFuture(respond(to: request.method, path: path, body: body))
    }

    private func respond(to method: HTTPMethod, path: String, body: String?) -> ClientResponse {
        if forbidsWrites, method == .POST {
            return json(
                status: .forbidden,
                #"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"This request is forbidden for security reasons"}]}"#
            )
        }
        switch (method, path) {
        case (.GET, "/v1/bundleIds"):
            return json(
                existingBundleID
                    ? #"{"data":[{"id":"bid-1","attributes":{"identifier":"com.example.tool","name":"도구","platform":"UNIVERSAL"}}]}"#
                    // 앞부분이 같은 다른 App ID 는 같은 것으로 보면 안 된다.
                    : #"{"data":[{"id":"bid-x","attributes":{"identifier":"com.example.tool.helper","name":"x","platform":"MAC_OS"}}]}"#
            )
        case (.POST, "/v1/bundleIds"):
            return json(
                status: .created,
                #"{"data":{"id":"bid-1","attributes":{"identifier":"com.example.tool","name":"도구","platform":"MAC_OS"}}}"#
            )
        case (.GET, "/v1/bundleIds/bid-1/bundleIdCapabilities"):
            let items = enabledCapabilities.enumerated().map {
                #"{"id":"cap-\#($0.offset)","attributes":{"capabilityType":"\#($0.element)"}}"#
            }
            return json(#"{"data":[\#(items.joined(separator: ","))]}"#)
        case (.POST, "/v1/bundleIdCapabilities"):
            return json(
                status: .created,
                #"{"data":{"id":"cap-new","attributes":{"capabilityType":"ICLOUD"}}}"#
            )
        case (.GET, "/v1/certificates") where noLiveCertificates:
            return json(
                #"""
                {"data":[
                  {"id":"cert-expired","attributes":{"name":"Developer ID Application","certificateType":"DEVELOPER_ID_APPLICATION","expirationDate":"2020-01-01T00:00:00Z"}}
                ]}
                """#
            )
        case (.GET, "/v1/certificates"):
            return json(
                #"""
                {"data":[
                  {"id":"cert-devid","attributes":{"name":"Developer ID Application","certificateType":"DEVELOPER_ID_APPLICATION_G2","expirationDate":"2031-01-01T00:00:00Z"}},
                  {"id":"cert-expired","attributes":{"name":"Developer ID Application","certificateType":"DEVELOPER_ID_APPLICATION","expirationDate":"2020-01-01T00:00:00Z"}},
                  {"id":"cert-dev","attributes":{"name":"Apple Development","certificateType":"DEVELOPMENT","expirationDate":"2031-01-01T00:00:00Z"}}
                ]}
                """#
            )
        case (.POST, "/v1/profiles"):
            let number = profileCounter.withLockedValue { value -> Int in
                value += 1
                return value
            }
            let allowed = profileAllows ?? ["com.apple.developer.icloud-services"]
            let content = (
                emptyContainers
                    ? FakeProfile.withEmptyContainers()
                    : FakeProfile.make(allowing: allowed)
            ).base64EncodedString()
            return json(
                status: .created,
                #"{"data":{"id":"profile-\#(number)","attributes":{"name":"Alley com.example.tool","profileContent":"\#(content)","expirationDate":"2044-11-23T10:30:00Z"}}}"#
            )
        case (.DELETE, _):
            return ClientResponse(status: .noContent)
        default:
            return json(status: .notFound, #"{"errors":[{"title":"없는 경로","detail":"\#(path)"}]}"#)
        }
    }

    private func json(status: HTTPResponseStatus = .ok, _ text: String) -> ClientResponse {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return ClientResponse(status: status, headers: headers, body: ByteBuffer(string: text))
    }
}
