import AlleyShared
import Foundation
import Testing

@testable import AlleyWorkerCore

@Suite("권한 판정")
struct EntitlementsTests {
    @Test("프로필이 필요한 권한을 알아본다", arguments: [
        "com.apple.developer.icloud-services",
        "com.apple.developer.networking.networkextension",
        "com.apple.developer.applesignin",
    ])
    func recognizesRestricted(_ key: String) {
        #expect(Entitlements.isRestricted(key))
    }

    @Test("프로필 없이 서명할 수 있는 권한은 통과시킨다", arguments: [
        "com.apple.security.cs.allow-jit",
        "com.apple.security.app-sandbox",
        "com.apple.security.network.client",
    ])
    func allowsUnrestricted(_ key: String) {
        // 샌드박스·하드닝 관련 권한은 팀 허가가 필요 없다.
        #expect(!Entitlements.isRestricted(key))
    }

    @Test("plist 에서 키를 뽑는다")
    func readsKeysFromPropertyList() {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>com.apple.security.cs.allow-jit</key>
                <true/>
                <key>com.apple.developer.icloud-services</key>
                <array><string>CloudKit</string></array>
            </dict>
            </plist>
            """

        let keys = Entitlements.keys(fromPropertyList: Data(plist.utf8))
        #expect(keys == ["com.apple.developer.icloud-services", "com.apple.security.cs.allow-jit"])
    }

    @Test("서명이 없는 번들은 권한이 없는 것으로 본다")
    func emptyOutputMeansNoEntitlements() {
        // codesign 이 아무것도 못 읽으면 빈 출력이 온다. 권한을 안 쓰는 앱이 대부분이다.
        #expect(Entitlements.keys(fromPropertyList: Data()).isEmpty)
        #expect(Entitlements.keys(fromPropertyList: Data("쓰레기".utf8)).isEmpty)
    }

    @Test("프로필이 필요한 권한인데 프로필이 없으면 막는다")
    func blocksMissingProfile() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")

        // 그대로 서명하면 앱은 실행되는데 그 기능만 조용히 죽는다.
        #expect(throws: Entitlements.ValidationError.self) {
            try Entitlements.validate(
                bundle: app,
                declaredKeys: ["com.apple.developer.icloud-services"]
            )
        }
    }

    @Test("프로필이 그 권한을 허용하면 통과한다")
    func passesWithProfile() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app/Contents")
            .deletingLastPathComponent()
        try FakeProfile.make(allowing: ["com.apple.developer.icloud-services"])
            .write(to: Entitlements.profileLocation(in: app))

        try Entitlements.validate(
            bundle: app,
            declaredKeys: ["com.apple.developer.icloud-services"]
        )
    }

    /// 프로필이 있다고 끝이 아니다. 허용하지 않는 권한으로 서명하면 공증은 통과하고
    /// 실행할 때 macOS 가 앱을 죽인다(`Unsatisfied entitlements`).
    @Test("프로필이 허용하지 않는 권한이 있으면 무엇인지 말하며 막는다")
    func blocksKeysTheProfileDoesNotAllow() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app/Contents")
            .deletingLastPathComponent()
        try FakeProfile.make(allowing: ["com.apple.developer.icloud-services"])
            .write(to: Entitlements.profileLocation(in: app))

        do {
            try Entitlements.validate(
                bundle: app,
                declaredKeys: [
                    "com.apple.developer.icloud-services",
                    "com.apple.developer.aps-environment",
                ]
            )
            Issue.record("막혀야 한다")
        } catch let error as Entitlements.ValidationError {
            guard case .profileDoesNotAllow(_, let keys, let disallowed, let details) = error else {
                Issue.record("프로필 불일치로 막아야 한다: \(error)")
                return
            }
            #expect(disallowed == ["com.apple.developer.aps-environment"])
            #expect(details == ["com.apple.developer.aps-environment: 프로필에 없음"])
            // 서버에는 모자란 것만이 아니라 전체를 보낸다.
            #expect(keys == ["com.apple.developer.aps-environment", "com.apple.developer.icloud-services"])
            #expect(error.failureCode == .provisioningProfileRequired)
        }
    }

    @Test("읽을 수 없는 프로필은 없는 것과 같이 다룬다")
    func unreadableProfileIsReported() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeFile("도구.app/Contents/embedded.provisionprofile", contents: "프로필 아님")

        #expect(throws: Entitlements.ValidationError.self) {
            try Entitlements.validate(
                bundle: app, declaredKeys: ["com.apple.developer.icloud-services"]
            )
        }
    }

    @Test("Developer ID 로 못 쓰는 권한은 프로필이 있어도 막는다")
    func blocksUnsupportedEvenWithProfile() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app/Contents")
            .deletingLastPathComponent()
        try FakeProfile.make(allowing: ["com.apple.developer.applesignin"])
            .write(to: Entitlements.profileLocation(in: app))

        do {
            try Entitlements.validate(
                bundle: app, declaredKeys: ["com.apple.developer.applesignin"]
            )
            Issue.record("막혀야 한다")
        } catch let error as Entitlements.ValidationError {
            #expect(error.failureCode == .entitlementsRejected)
        }
    }

    @Test("접두사가 달라도 프로필이 필요한 권한을 알아본다", arguments: [
        "keychain-access-groups",
        "com.apple.application-identifier",
    ])
    func recognizesRestrictedWithoutPrefix(_ key: String) {
        // 예전 기준은 이 둘을 놓쳐서 실행할 때 죽는 앱을 통과시켰다.
        #expect(Entitlements.isRestricted(key))
    }

    @Test("App Group 은 프로필 없이 서명된다")
    func appGroupsAreUnrestricted() {
        // TN3125 가 프로필 없이 쓸 수 있다고 적은 것이다.
        #expect(!Entitlements.isRestricted("com.apple.security.application-groups"))
    }

    // MARK: - 프로필 넣기

    @Test("스토어 프로필이 번들에 있던 것을 덮어쓴다")
    func installReplacesExistingProfile() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")
        try fixture.makeFile("도구.app/Contents/embedded.provisionprofile", contents: "개발자 것")

        let store = FakeProfile.make(allowing: ["com.apple.developer.icloud-services"])
        let replaced = try Entitlements.installProfile(store, into: app)

        #expect(replaced)
        #expect(try Data(contentsOf: Entitlements.profileLocation(in: app)) == store)
    }

    /// 올린 zip 은 링크를 그대로 풀어 놓는다. 따라가면 작업 디렉터리 밖을 덮어쓴다.
    @Test("Contents 가 심볼릭 링크면 프로필을 쓰지 않는다")
    func installRefusesSymbolicLinks() throws {
        let fixture = try BundleFixture()
        let outside = try fixture.makeDirectory("바깥")
        let app = try fixture.makeDirectory("도구.app")
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("Contents"), withDestinationURL: outside
        )

        #expect(throws: Entitlements.InstallError.self) {
            try Entitlements.installProfile(FakeProfile.make(allowing: []), into: app)
        }
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("embedded.provisionprofile").path
        ))
    }

    /// 없는 곳을 가리키는 링크면 "이미 있음" 검사가 거짓이라 쓰기가 링크를 따라간다.
    @Test("프로필 자리가 바깥을 가리키는 링크면 쓰지 않는다")
    func installRefusesDanglingProfileLink() throws {
        let fixture = try BundleFixture()
        let outside = try fixture.makeDirectory("바깥")
        let app = try fixture.makeDirectory("도구.app/Contents").deletingLastPathComponent()
        let target = outside.appendingPathComponent("생길-파일")
        try FileManager.default.createSymbolicLink(
            at: Entitlements.profileLocation(in: app), withDestinationURL: target
        )

        #expect(throws: Entitlements.InstallError.self) {
            try Entitlements.installProfile(FakeProfile.make(allowing: []), into: app)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// 바깥 앱의 대조는 바깥 프로필만 본다. 헬퍼가 자기 프로필을 가졌으면 그것으로도
    /// 대조해야 한다. 스토어가 풀 수 없는 실패라 프로필 갈래가 아니다.
    @Test("자기 프로필을 가진 헬퍼도 그 프로필로 대조한다")
    func validatesHelpersWithOwnProfile() async throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app/Contents").deletingLastPathComponent()
        let helper = try fixture.makeDirectory("도구.app/Contents/Library/LoginItems/도우미.app/Contents")
            .deletingLastPathComponent()
        try FakeProfile.make(allowing: ["com.apple.developer.icloud-services"])
            .write(to: Entitlements.profileLocation(in: helper))
        let both = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
            <key>com.apple.developer.aps-environment</key><string>production</string>
            </dict></plist>
            """.utf8)
        let icloudOnly = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
            </dict></plist>
            """.utf8)

        do {
            try await SigningPipeline.validateHelpersWithOwnProfile(
                [helper, app], of: AppBundle(url: app), provided: both
            )
            Issue.record("헬퍼 프로필이 허용하지 않는 권한이 있으면 막아야 한다")
        } catch let error as SigningPipeline.PipelineError {
            #expect(error.failureCode == .entitlementsRejected)
            #expect(error.description.contains("도우미.app"))
            #expect(error.description.contains("com.apple.developer.aps-environment"))
        }

        // 헬퍼 프로필과 맞으면 통과한다.
        try await SigningPipeline.validateHelpersWithOwnProfile(
            [helper, app], of: AppBundle(url: app), provided: icloudOnly
        )
    }

    @Test("번들에 프로필이 없으면 새로 넣는다")
    func installAddsProfile() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app/Contents")
            .deletingLastPathComponent()

        let replaced = try Entitlements.installProfile(FakeProfile.make(allowing: []), into: app)

        #expect(!replaced)
        #expect(Entitlements.hasProvisioningProfile(in: app))
    }

    /// macOS 는 이 값으로 번들의 프로필이 이 앱 것인지 확인한다. 손으로 만든 plist 에는
    /// 대개 없고, 다른 팀으로 서명됐던 빌드에는 옛 팀의 값이 남아 있다.
    @Test("앱 신원을 프로필 값으로 맞춘다")
    func appliesProfileIdentity() throws {
        let profile = ProvisioningProfile(
            teamIdentifier: "TEAM123456",
            entitlementKeys: ["com.apple.application-identifier"],
            applicationIdentifier: "TEAM123456.com.example.tool"
        )
        let plist = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
            </dict></plist>
            """.utf8)

        let filled = Entitlements.applyingProfileIdentity(to: plist, from: profile)
        let dictionary = try #require(
            PropertyListSerialization.propertyList(from: filled, format: nil) as? [String: Any]
        )
        #expect(dictionary["com.apple.application-identifier"] as? String == "TEAM123456.com.example.tool")
        #expect(dictionary["com.apple.developer.team-identifier"] as? String == "TEAM123456")
        #expect(dictionary["com.apple.developer.icloud-services"] != nil)

        // 이미 맞으면 손대지 않는다.
        #expect(Entitlements.applyingProfileIdentity(to: filled, from: profile) == filled)
    }

    /// 키만 보는 대조로는 못 잡는다. 공증까지 통과한 뒤 실행할 때 죽는다.
    @Test("다른 팀의 앱 신원이 남아 있으면 프로필 값으로 덮어쓴다")
    func overwritesForeignIdentity() throws {
        let profile = ProvisioningProfile(
            teamIdentifier: "TEAM123456",
            entitlementKeys: ["com.apple.application-identifier"],
            applicationIdentifier: "TEAM123456.com.example.tool"
        )
        let plist = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>com.apple.application-identifier</key><string>OTHERTEAM.com.example.tool</string>
            <key>com.apple.developer.team-identifier</key><string>OTHERTEAM</string>
            </dict></plist>
            """.utf8)

        let filled = Entitlements.applyingProfileIdentity(to: plist, from: profile)
        let dictionary = try #require(
            PropertyListSerialization.propertyList(from: filled, format: nil) as? [String: Any]
        )
        #expect(dictionary["com.apple.application-identifier"] as? String == "TEAM123456.com.example.tool")
        #expect(dictionary["com.apple.developer.team-identifier"] as? String == "TEAM123456")
    }

    /// capability 만 켜고 컨테이너를 연결하지 않은 프로필은 키는 있고 값이 비어 있다.
    @Test("키가 있어도 값이 프로필에 없으면 막는다")
    func blocksValuesTheProfileLacks() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app/Contents")
            .deletingLastPathComponent()
        let profile = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>Entitlements</key><dict>
            <key>com.apple.developer.icloud-container-identifiers</key><array/>
            <key>keychain-access-groups</key><array><string>TEAM123456.*</string></array>
            </dict></dict></plist>
            """
        try Data(profile.utf8).write(to: Entitlements.profileLocation(in: app))
        let declared = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>com.apple.developer.icloud-container-identifiers</key>
            <array><string>iCloud.com.example.tool</string></array>
            <key>keychain-access-groups</key><array><string>TEAM123456.com.example.shared</string></array>
            </dict></plist>
            """.utf8)

        do {
            try Entitlements.validate(bundle: app, propertyList: declared)
            Issue.record("막혀야 한다")
        } catch let error as Entitlements.ValidationError {
            // 키체인 그룹은 와일드카드로 허용된다. 걸리는 것은 컨테이너뿐이다.
            guard case .profileDoesNotAllow(_, let keys, let disallowed, let details) = error else {
                Issue.record("프로필 불일치로 막아야 한다: \(error)")
                return
            }
            #expect(disallowed == ["com.apple.developer.icloud-container-identifiers"])
            // 무엇을 고칠지는 값을 봐야 안다. 선언한 값과 프로필이 허용하는 값을 함께 적고,
            // 화면은 실패 사유의 첫 줄만 보이므로 한 줄에 둔다.
            #expect(details == [
                "com.apple.developer.icloud-container-identifiers: iCloud.com.example.tool (프로필 허용: 없음)"
            ])
            #expect(error.description.contains("iCloud.com.example.tool (프로필 허용: 없음)"))
            #expect(!error.description.contains("\n"))
            // 서버에는 전체를 보낸다. 새 프로필이 나머지를 빠뜨리지 않게 한다.
            #expect(keys.count == 2)
        }
    }

    @Test("헬퍼에 붙일 plist 에서 프로필이 필요한 권한을 뺀다")
    func stripsRestrictedKeysForHelpers() throws {
        let plist = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>com.apple.security.cs.allow-jit</key><true/>
            <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
            <key>keychain-access-groups</key><array><string>TEAM.*</string></array>
            </dict></plist>
            """.utf8)

        let stripped = Entitlements.removingProfileRequired(from: plist)

        // 헬퍼에는 프로필이 없다. 그 권한을 실으면 헬퍼가 뜨자마자 죽는다.
        #expect(Entitlements.keys(fromPropertyList: stripped) == ["com.apple.security.cs.allow-jit"])
    }

    @Test("프로필이 필요 없는 권한만 쓰면 프로필 없이 통과한다")
    func passesWithoutRestrictedKeys() throws {
        let fixture = try BundleFixture()
        let app = try fixture.makeDirectory("도구.app")

        try Entitlements.validate(bundle: app, declaredKeys: ["com.apple.security.cs.allow-jit"])
    }

    @Test("권한이 없으면 파일을 만들지 않는다")
    func writesNothingForEmptyEntitlements() throws {
        let fixture = try BundleFixture()
        let target = fixture.root.appendingPathComponent("entitlements.plist")

        // 빈 --entitlements 파일을 넘기면 codesign 이 오히려 권한을 지운다.
        #expect(Entitlements.writePropertyList(Data(), to: target) == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
