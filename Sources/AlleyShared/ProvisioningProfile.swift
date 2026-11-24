import Foundation

/// 프로비저닝 프로필 파일에서 우리가 쓰는 값만 읽은 것.
///
/// 프로필은 CMS(PKCS#7) 서명으로 감싼 XML plist 다. 서명을 검증하는 것은 macOS 의
/// 몫이고 우리는 **안에 든 plist 를 읽기만** 한다. 감싼 껍데기가 내용을 암호화하지
/// 않아서, 바이트 안에서 `<?xml` 부터 `</plist>` 까지를 잘라내면 원문 그대로다.
///
/// **서버가 리눅스라 이렇게 읽는다.** macOS 에는 `security cms -D` 가 있지만 서버에는
/// 없다. 발급한 프로필이 무엇을 허용하는지 서버도 알아야 화면에 말할 수 있고, 워커와
/// 서버가 같은 코드로 읽어야 둘의 판단이 갈리지 않는다.
public struct ProvisioningProfile: Sendable, Equatable {
    /// 번들 안에서 프로필이 놓이는 자리. macOS 앱은 이 이름 하나만 본다.
    public static let bundlePath = "Contents/embedded.provisionprofile"

    public var name: String?
    public var uuid: String?
    public var teamIdentifier: String?
    public var expiresAt: Date?
    /// 프로필이 허용하는 권한 키. 정렬돼 있다.
    public var entitlementKeys: [String]
    /// `com.apple.application-identifier` 의 값. `TEAMID.번들ID` 꼴이다.
    ///
    /// 서명할 때 이 값을 권한에 그대로 실어야 macOS 가 프로필이 이 앱 것인지 확인한다.
    public var applicationIdentifier: String?
    /// 문자열이나 문자열 배열로 된 권한 값. 하나짜리 문자열도 배열로 담는다.
    ///
    /// iCloud 컨테이너처럼 **키는 있는데 값이 비어 있는** 프로필이 실제로 나온다.
    /// capability 만 켜고 컨테이너를 연결하지 않으면 그렇다. 키만 보면 통과하고 실행할
    /// 때 죽으므로 값도 담아 둔다.
    public var entitlementValues: [String: [String]]

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noPropertyList
        case notADictionary

        public var description: String {
            switch self {
            case .noPropertyList:
                return "프로비저닝 프로필 안에서 plist 를 찾지 못했습니다. 파일이 깨졌거나 프로필이 아닙니다."
            case .notADictionary:
                return "프로비저닝 프로필의 plist 가 사전이 아닙니다."
            }
        }
    }

    public init(
        name: String? = nil,
        uuid: String? = nil,
        teamIdentifier: String? = nil,
        expiresAt: Date? = nil,
        entitlementKeys: [String],
        applicationIdentifier: String? = nil,
        entitlementValues: [String: [String]] = [:]
    ) {
        self.name = name
        self.uuid = uuid
        self.teamIdentifier = teamIdentifier
        self.expiresAt = expiresAt
        self.entitlementKeys = entitlementKeys.sorted()
        self.applicationIdentifier = applicationIdentifier
        self.entitlementValues = entitlementValues
    }

    /// 프로필 파일의 바이트를 읽는다.
    public init(data: Data) throws {
        guard let plist = Self.embeddedPropertyList(in: data) else {
            throw ParseError.noPropertyList
        }
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: plist, options: [], format: nil
        ) else {
            throw ParseError.noPropertyList
        }
        guard let root = parsed as? [String: Any] else {
            throw ParseError.notADictionary
        }

        let entitlements = root["Entitlements"] as? [String: Any] ?? [:]
        self.init(
            name: root["Name"] as? String,
            uuid: root["UUID"] as? String,
            teamIdentifier: (root["TeamIdentifier"] as? [String])?.first,
            expiresAt: root["ExpirationDate"] as? Date,
            entitlementKeys: Array(entitlements.keys),
            applicationIdentifier: entitlements["com.apple.application-identifier"] as? String,
            entitlementValues: Self.stringValues(of: entitlements)
        )
    }

    /// 권한 사전에서 문자열 값만 뽑는다. 참·거짓 같은 값은 키만 본다.
    public static func stringValues(of entitlements: [String: Any]) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for (key, value) in entitlements {
            if let string = value as? String {
                values[key] = [string]
            } else if let array = value as? [Any] {
                let strings = array.compactMap { $0 as? String }
                if strings.count == array.count { values[key] = strings }
            }
        }
        return values
    }

    /// 서명이 이 값으로 덮어쓰는 신원 키. 대조하지 않는다.
    ///
    /// 워커가 프로필의 값으로 바꿔 서명하므로(`Entitlements.applyingProfileIdentity`),
    /// 번들에 원래 무엇이 적혀 있었든 결과는 프로필과 같다.
    public static let identityKeys: Set<String> = [
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
    ]

    /// 선언한 권한 중 이 프로필이 허용하지 않는 것. 값까지 본다.
    ///
    /// 키가 없으면 허용하지 않는 것이다. 키가 있고 양쪽 값이 문자열이면, 선언한 값
    /// 하나하나가 프로필 값 중 하나에 맞아야 한다. 프로필 값의 `*` 는 무엇이든,
    /// `TEAMID.*` 처럼 끝의 `*` 는 앞부분이 같은 것을 받는다. iCloud 컨테이너를
    /// 연결하지 않은 프로필은 값이 빈 배열이라 여기서 걸린다.
    public func disallowedKeys(declared: [String: [String]?]) -> [String] {
        let allowed = Set(entitlementKeys)
        return EntitlementsPlist.requiringProvisioningProfile(in: declared.keys).filter { key in
            guard allowed.contains(key) else { return true }
            guard !Self.identityKeys.contains(key),
                  let requested = declared[key] ?? nil,
                  let granted = entitlementValues[key]
            else {
                return false
            }
            return !requested.allSatisfy { value in
                granted.contains { Self.matches(pattern: $0, value: value) }
            }
        }
    }

    static func matches(pattern: String, value: String) -> Bool {
        if pattern == "*" || pattern == value { return true }
        guard pattern.hasSuffix("*") else { return false }
        return value.hasPrefix(String(pattern.dropLast()))
    }

    /// 선언한 권한 중 이 프로필이 허용하지 않는 것.
    ///
    /// **키가 있는지만 본다.** 값까지 맞추려면 키마다 규칙이 다르다. iCloud 컨테이너는
    /// 배열의 부분집합이어야 하고, 키체인 그룹은 `TEAMID.*` 같은 와일드카드를 품고,
    /// Push 환경은 문자열 하나다. 키가 빠진 것이 실제로 가장 흔한 어긋남이고, 값이
    /// 어긋나면 그때는 codesign 이나 실행이 말해준다.
    ///
    /// 프로필이 필요 없는 권한은 대조하지 않는다. 하드닝·샌드박스 권한은 프로필에
    /// 실리지 않는다.
    public func missingKeys(for declared: some Sequence<String>) -> [String] {
        let allowed = Set(entitlementKeys)
        return EntitlementsPlist.requiringProvisioningProfile(in: declared)
            .filter { !allowed.contains($0) }
    }

    /// CMS 로 감싼 바이트 안에서 plist 원문을 잘라낸다.
    static func embeddedPropertyList(in data: Data) -> Data? {
        let start = Data("<?xml".utf8)
        let end = Data("</plist>".utf8)
        guard let head = data.range(of: start),
              let tail = data.range(of: end, in: head.upperBound..<data.endIndex)
        else {
            return nil
        }
        return data.subdata(in: head.lowerBound..<tail.upperBound)
    }
}
