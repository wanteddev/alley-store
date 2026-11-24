import AlleyShared
import Foundation
import Testing

/// 서버(리눅스)와 워커(macOS)가 같은 코드로 프로필을 읽는다 (ADR-0085). `security cms`
/// 없이 CMS 안의 plist 를 꺼내는 것이 여기서 지키는 것이다.
@Suite("프로비저닝 프로필 읽기")
struct ProvisioningProfileTests {
    @Test("CMS 껍데기 안의 plist 에서 값을 읽는다")
    func readsEmbeddedPropertyList() throws {
        let data = FakeProfile.make(
            allowing: ["com.apple.developer.icloud-services", "keychain-access-groups"]
        )

        let profile = try ProvisioningProfile(data: data)

        #expect(profile.name == "Alley com.example.tool")
        #expect(profile.teamIdentifier == "TEAM123456")
        #expect(profile.applicationIdentifier == "TEAM123456.com.example.tool")
        #expect(profile.entitlementKeys == [
            "com.apple.application-identifier",
            "com.apple.developer.icloud-services",
            "keychain-access-groups",
        ])
        let expected = ISO8601DateFormatter().date(from: "2044-11-23T10:30:00Z")
        #expect(profile.expiresAt == expected)
    }

    @Test("plist 가 없으면 프로필이 아니라고 말한다")
    func rejectsNonProfile() {
        #expect(throws: ProvisioningProfile.ParseError.noPropertyList) {
            try ProvisioningProfile(data: Data("프로필 아님".utf8))
        }
    }

    @Test("프로필이 허용하지 않는 키만 골라낸다")
    func findsMissingKeys() {
        let profile = ProvisioningProfile(
            entitlementKeys: ["com.apple.developer.icloud-services"]
        )

        let missing = profile.missingKeys(for: [
            "com.apple.developer.icloud-services",
            "com.apple.developer.aps-environment",
            // 하드닝 권한은 프로필에 실리지 않는다. 대조하면 늘 모자란 것으로 나온다.
            "com.apple.security.cs.allow-jit",
        ])

        #expect(missing == ["com.apple.developer.aps-environment"])
    }
}

@Suite("프로필이 필요한 권한")
struct ProfileRequirementTests {
    @Test("접두사가 다른 것도 프로필이 필요하다", arguments: [
        "keychain-access-groups",
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
    ])
    func restrictedKeys(_ key: String) {
        #expect(EntitlementsPlist.requiresProvisioningProfile(key))
    }

    @Test("샌드박스·하드닝·App Group 은 프로필이 필요 없다", arguments: [
        "com.apple.security.app-sandbox",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.application-groups",
    ])
    func unrestrictedKeys(_ key: String) {
        #expect(!EntitlementsPlist.requiresProvisioningProfile(key))
    }

    @Test("Developer ID 로 못 쓰는 권한을 골라낸다")
    func findsUnsupported() {
        let found = EntitlementsPlist.unsupportedForDeveloperID(in: [
            "com.apple.developer.applesignin",
            "com.apple.developer.icloud-services",
            "com.apple.developer.weatherkit",
        ])
        #expect(found == ["com.apple.developer.applesignin", "com.apple.developer.weatherkit"])
    }
}
