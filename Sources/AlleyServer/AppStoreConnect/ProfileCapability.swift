import AlleyShared
import Foundation

/// App ID 에 켜는 capability 중 스토어가 알아서 켜는 것 (ADR-0084).
///
/// 값은 App Store Connect API 의 `CapabilityType` 이다. **맥의 Developer ID 앱이 쓸 수
/// 있고, API 로 켤 수 있는 것만 둔다.** Sign in with Apple 처럼 Developer ID 가 못 쓰는
/// 것은 `EntitlementsPlist.unsupportedForDeveloperID` 가 먼저 막고, WeatherKit 처럼
/// API 에 값이 없는 것은 켤 방법이 없어서 사람에게 넘긴다.
public enum ProfileCapability: String, CaseIterable, Sendable, Comparable {
    case iCloud = "ICLOUD"
    case pushNotifications = "PUSH_NOTIFICATIONS"
    case associatedDomains = "ASSOCIATED_DOMAINS"
    case networkExtensions = "NETWORK_EXTENSIONS"
    case personalVPN = "PERSONAL_VPN"
    case systemExtensionInstall = "SYSTEM_EXTENSION_INSTALL"
    case autoFillCredentialProvider = "AUTOFILL_CREDENTIAL_PROVIDER"
    case maps = "MAPS"
    case applePay = "APPLE_PAY"
    case classKit = "CLASSKIT"

    /// 이 capability 를 요구하는 권한 키.
    ///
    /// Apple 은 이 대응을 표로 내놓지 않는다. 키 이름과 capability 이름을 맞춰 본 것이라,
    /// 여기 없는 키는 "모른다" 로 다룬다. 모르는 키도 프로필은 만들고, 만든 프로필이
    /// 그 키를 허용하는지 보고 사람에게 말한다 (`ProfilePlan`).
    var entitlementKeys: [String] {
        switch self {
        case .iCloud:
            return [
                "com.apple.developer.icloud-container-identifiers",
                "com.apple.developer.icloud-container-development-container-identifiers",
                "com.apple.developer.icloud-container-environment",
                "com.apple.developer.icloud-services",
                "com.apple.developer.ubiquity-container-identifiers",
                "com.apple.developer.ubiquity-kvstore-identifier",
            ]
        case .pushNotifications: return ["com.apple.developer.aps-environment"]
        case .associatedDomains: return ["com.apple.developer.associated-domains"]
        case .networkExtensions: return ["com.apple.developer.networking.networkextension"]
        case .personalVPN: return ["com.apple.developer.networking.vpn.api"]
        case .systemExtensionInstall: return ["com.apple.developer.system-extension.install"]
        case .autoFillCredentialProvider:
            return ["com.apple.developer.authentication-services.autofill-credential-provider"]
        case .maps: return ["com.apple.developer.maps"]
        case .applePay: return ["com.apple.developer.in-app-payments"]
        case .classKit: return ["com.apple.developer.ClassKit-environment"]
        }
    }

    /// 켜고 나서도 Apple 화면에서 사람이 할 일이 남는가. 남으면 그 일을 적은 문장.
    ///
    /// iCloud 컨테이너와 Apple Pay 판매자 ID 는 App ID 에 연결해야 프로필에 실리는데,
    /// ASC API 에는 그 엔드포인트가 없다. 켜기까지만 하고 무엇을 해야 하는지 말한다.
    /// **어느 화면에서 무엇을 누르는지 끝까지 적는다.** "Apple 화면에서 연결하세요" 만
    /// 쓰면 그 화면을 처음 여는 사람은 어디서부터 찾아야 할지 모른다.
    func portalChore(bundleID: String) -> String? {
        switch self {
        case .iCloud:
            return """
                iCloud 컨테이너를 쓴다면 Apple Developer 사이트의 Certificates, Identifiers & \
                Profiles > Identifiers 목록에서 \(bundleID) 항목을 열어 iCloud 에 컨테이너를 \
                연결하고 저장한 뒤, 여기서 '프로필 다시 발급' 을 누르세요. App ID 설정이 바뀌면 \
                Apple 이 기존 프로필을 무효로 만들기 때문입니다.
                """
        case .applePay:
            return """
                Apple Developer 사이트의 Certificates, Identifiers & Profiles > Identifiers \
                목록에서 \(bundleID) 항목을 열어 Apple Pay 에 판매자 ID 를 연결하고 저장한 뒤, \
                여기서 '프로필 다시 발급' 을 누르세요. App ID 설정이 바뀌면 Apple 이 기존 \
                프로필을 무효로 만들기 때문입니다.
                """
        default:
            return nil
        }
    }

    /// 켤 때 함께 보내야 하는 설정.
    ///
    /// iCloud 는 버전을 골라야 한다. CloudKit 을 쓰려면 `XCODE_6` 이고, 그것이 지금
    /// Xcode 가 고르는 값이다.
    var settings: [Setting]? {
        switch self {
        case .iCloud:
            return [Setting(key: "ICLOUD_VERSION", options: [.init(key: "XCODE_6")])]
        default:
            return nil
        }
    }

    /// 화면에 쓰는 이름. Apple 개발자 화면의 이름을 따른다.
    var displayName: String {
        switch self {
        case .iCloud: return "iCloud"
        case .pushNotifications: return "Push Notifications"
        case .associatedDomains: return "Associated Domains"
        case .networkExtensions: return "Network Extensions"
        case .personalVPN: return "Personal VPN"
        case .systemExtensionInstall: return "System Extension"
        case .autoFillCredentialProvider: return "AutoFill Credential Provider"
        case .maps: return "Maps"
        case .applePay: return "Apple Pay"
        case .classKit: return "ClassKit"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    struct Setting: Encodable, Equatable {
        struct Option: Encodable, Equatable {
            var key: String
        }
        var key: String
        var options: [Option]
    }

    /// 값이 Apple 화면에서 연결한 식별자로 채워지는 키. 연결 전에는 프로필에 빈 값으로 온다.
    static let linkedValueKeys: Set<String> = [
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-container-development-container-identifiers",
        "com.apple.developer.ubiquity-container-identifiers",
        "com.apple.developer.in-app-payments",
    ]

    static func capability(for key: String) -> ProfileCapability? {
        allCases.first { $0.entitlementKeys.contains(key) }
    }
}

/// 권한 키 목록을 보고 프로필을 만들기 위해 무엇을 하는지 정한 것.
///
/// **누르기 전에 화면에 보이고, 누르면 그대로 한다.** 같은 계산을 두 번 하면 화면이 말한
/// 것과 실제로 한 일이 어긋날 수 있어서 한 곳에 둔다.
struct ProfilePlan: Equatable {
    /// 프로필이 있어야 하는 키 전부.
    var keys: [String]
    /// 켤 capability.
    var capabilities: [ProfileCapability]
    /// 켤 것 없이 모든 프로필에 실리는 키. 프로필을 만들기만 하면 된다.
    var implicit: [String]
    /// 대응표에 없는 키. 프로필을 만든 뒤 허용됐는지로 판단한다.
    var unmapped: [String]
    /// Developer ID 로는 쓸 수 없는 키. 있으면 발급하지 않는다.
    var unsupported: [String]

    /// 프로필이 capability 없이도 늘 담는 키.
    ///
    /// 앱 신원 두 줄은 모든 프로필에 들어 있고, 키체인 공유는 `TEAMID.*` 로 실린다.
    static let alwaysInProfile: Set<String> = [
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
        "keychain-access-groups",
    ]

    init(keys: some Sequence<String>) {
        let all = Set(keys)
        self.unsupported = EntitlementsPlist.unsupportedForDeveloperID(in: all)
        let restricted = EntitlementsPlist.requiringProvisioningProfile(in: all)
            .filter { !EntitlementsPlist.unsupportedForDeveloperID.contains($0) }
        self.keys = restricted

        var capabilities: Set<ProfileCapability> = []
        var implicit: [String] = []
        var unmapped: [String] = []
        for key in restricted {
            if let capability = ProfileCapability.capability(for: key) {
                capabilities.insert(capability)
            } else if Self.alwaysInProfile.contains(key) {
                implicit.append(key)
            } else {
                unmapped.append(key)
            }
        }
        self.capabilities = capabilities.sorted()
        self.implicit = implicit
        self.unmapped = unmapped
    }

    /// 사람이 Apple 화면에서 해야 할 일.
    func portalChores(bundleID: String) -> [String] {
        capabilities.compactMap { $0.portalChore(bundleID: bundleID) }
    }

    /// 만든 프로필이 그래도 허용하지 않는 키가 있을 때 하는 말.
    ///
    /// 화면(`IssuedProfileRow`)과 발급 직후 알림이 같은 문장을 쓴다.
    static func missingKeysAdvice(_ keys: [String], bundleID: String) -> String {
        """
        이 프로필이 아직 허용하지 않는 권한이 있습니다: \(keys.joined(separator: ", ")). \
        스토어가 켤 수 없는 capability 입니다. Apple Developer 사이트의 Certificates, \
        Identifiers & Profiles > Identifiers 목록에서 \(bundleID) 항목을 열어 이 권한에 \
        해당하는 capability 를 켜고 저장한 뒤, 여기서 '프로필 다시 발급' 을 누르세요.
        """
    }
}
