import AlleyProcess
import AlleyShared
import Foundation

/// 번들이 요구하는 권한과, 그것을 서명할 수 있는지에 대한 판단.
///
/// 여기서 걸러내지 않으면 서명은 성공하고 공증까지 통과한 뒤, 사용자의 맥에서
/// 실행할 때가 되어서야 조용히 기능이 동작하지 않는다. 그때는 원인을 찾기 어렵다.
public enum Entitlements {
    /// 프로비저닝 프로필이 있어야 쓸 수 있는 권한인지.
    ///
    /// 판정은 `AlleyShared` 에 있다. 서명을 멈추는 쪽과 포털에 App ID 를 권하는 쪽이
    /// 같은 기준을 써야 하기 때문이다.
    public static func isRestricted(_ key: String) -> Bool {
        EntitlementsPlist.requiresProvisioningProfile(key)
    }

    public static func restricted(in keys: some Sequence<String>) -> [String] {
        EntitlementsPlist.requiringProvisioningProfile(in: keys)
    }

    /// 번들 안에서 프로필이 놓이는 자리.
    public static func profileLocation(in bundle: URL) -> URL {
        bundle.appendingPathComponent(ProvisioningProfile.bundlePath)
    }

    /// 번들에 프로비저닝 프로필이 들어 있는지.
    public static func hasProvisioningProfile(in bundle: URL) -> Bool {
        FileManager.default.fileExists(atPath: profileLocation(in: bundle).path)
    }

    /// 번들에 든 프로필을 읽는다. 없으면 nil, 있는데 못 읽으면 던진다.
    public static func embeddedProfile(in bundle: URL) throws -> ProvisioningProfile? {
        let location = profileLocation(in: bundle)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        return try ProvisioningProfile(data: Data(contentsOf: location))
    }

    /// 이 번들을 지금 서명해도 되는지 판단한다.
    ///
    /// 세 가지를 본다. 순서는 "사람이 무엇을 고쳐야 하나" 가 다른 순서다.
    ///
    /// 1. Developer ID 로는 아예 못 쓰는 권한이 있으면 멈춘다. 프로필로 풀 수 없다
    /// 2. 프로필이 필요한 권한을 쓰는데 프로필이 없으면 멈춘다. 그대로 서명하면
    ///    codesign 이 권한을 조용히 떨어뜨리거나, 설치한 뒤 그 기능만 동작하지 않는다
    /// 3. 프로필이 있으면 그 프로필이 권한을 다 허용하는지 본다. 어긋나면 macOS 가
    ///    실행할 때 앱을 죽인다(`Unsatisfied entitlements`). 공증은 통과하므로 여기서
    ///    잡지 않으면 사용자의 맥에서야 드러난다
    public static func validate(bundle: URL, declaredKeys: [String]) throws {
        var declared: [String: [String]?] = [:]
        for key in declaredKeys { declared[key] = .some(nil) }
        try validate(bundle: bundle, declared: declared)
    }

    /// plist 원문으로 판단한다. 값까지 대조할 수 있다.
    public static func validate(bundle: URL, propertyList: Data) throws {
        let dictionary = dictionary(fromPropertyList: propertyList) ?? [:]
        let values = ProvisioningProfile.stringValues(of: dictionary)
        var declared: [String: [String]?] = [:]
        for key in dictionary.keys { declared[key] = .some(values[key]) }
        try validate(bundle: bundle, declared: declared)
    }

    /// 키마다 문자열 값(없으면 nil)을 받는다.
    static func validate(bundle: URL, declared: [String: [String]?]) throws {
        let name = bundle.lastPathComponent
        let declaredKeys = Array(declared.keys)
        let unsupported = EntitlementsPlist.unsupportedForDeveloperID(in: declaredKeys)
        guard unsupported.isEmpty else {
            throw ValidationError.unsupportedForDeveloperID(bundle: name, keys: unsupported)
        }

        let restricted = restricted(in: declaredKeys)
        guard !restricted.isEmpty else { return }

        let profile: ProvisioningProfile?
        do {
            profile = try embeddedProfile(in: bundle)
        } catch {
            throw ValidationError.unreadableProfile(bundle: name, keys: restricted)
        }
        guard let profile else {
            throw ValidationError.missingProfile(bundle: name, keys: restricted)
        }

        let disallowed = profile.disallowedKeys(declared: declared)
        guard disallowed.isEmpty else {
            throw ValidationError.profileDoesNotAllow(
                bundle: name, keys: restricted, disallowed: disallowed
            )
        }
    }

    public enum ValidationError: Error, CustomStringConvertible {
        case missingProfile(bundle: String, keys: [String])
        /// `keys` 는 서명에 필요한 전체, `disallowed` 는 그중 프로필이 허용하지 않는 것.
        case profileDoesNotAllow(bundle: String, keys: [String], disallowed: [String])
        case unreadableProfile(bundle: String, keys: [String])
        case unsupportedForDeveloperID(bundle: String, keys: [String])

        /// 서버에 알릴 "프로필이 있어야 하는 권한". 프로필로 풀 수 없는 실패면 nil.
        ///
        /// **모자란 것만이 아니라 전체를 보낸다.** 서버는 이것으로 새 프로필을 만든다.
        /// 모자란 키만 보내면 새 프로필이 나머지를 빠뜨리고, 다음 시도에서 또 멈춘다.
        public var profileKeys: [String]? {
            switch self {
            case .missingProfile(_, let keys),
                 .profileDoesNotAllow(_, let keys, _),
                 .unreadableProfile(_, let keys):
                return keys
            case .unsupportedForDeveloperID:
                return nil
            }
        }

        /// 고칠 것이 프로필이면 프로필 갈래, 앱이면 entitlements 갈래.
        public var failureCode: SigningFailureCode {
            profileKeys == nil ? .entitlementsRejected : .provisioningProfileRequired
        }

        public var description: String {
            switch self {
            case .missingProfile(let bundle, let keys):
                return """
                    \(bundle) 은 프로비저닝 프로필이 필요한 권한을 쓰는데 프로필이 들어 있지 \
                    않습니다: \(keys.joined(separator: ", ")).
                    """
            case .profileDoesNotAllow(let bundle, _, let disallowed):
                return """
                    \(bundle) 에 든 프로비저닝 프로필이 이 권한을 허용하지 않습니다: \
                    \(disallowed.joined(separator: ", ")). 키가 없거나, iCloud 컨테이너처럼 \
                    값이 프로필에 연결되지 않았습니다. 이대로 서명하면 공증은 통과하지만 \
                    실행할 때 macOS 가 앱을 멈춥니다.
                    """
            case .unreadableProfile(let bundle, let keys):
                return """
                    \(bundle) 에 든 프로비저닝 프로필을 읽지 못했습니다. 이 권한에 프로필이 \
                    필요합니다: \(keys.joined(separator: ", ")).
                    """
            case .unsupportedForDeveloperID(let bundle, let keys):
                return """
                    \(bundle) 이 Developer ID 로 배포하는 앱은 쓸 수 없는 권한을 씁니다: \
                    \(keys.joined(separator: ", ")). 프로필로도 풀리지 않습니다. 이 권한을 \
                    빼고 다시 빌드해야 합니다.
                    """
            }
        }
    }

    // MARK: - 프로필 넣기

    /// 스토어가 준 프로필을 번들에 넣는다. 원래 있던 것을 덮어썼으면 true.
    ///
    /// **서명보다 먼저 해야 한다.** 프로필은 번들의 리소스라 봉인에 들어간다. 서명한
    /// 뒤에 넣으면 봉인이 깨진다.
    @discardableResult
    public static func installProfile(_ data: Data, into bundle: URL) throws -> Bool {
        let location = profileLocation(in: bundle)
        let replaced = FileManager.default.fileExists(atPath: location.path)
        if replaced { try FileManager.default.removeItem(at: location) }
        try data.write(to: location)
        return replaced
    }

    /// 프로필을 쓰는 앱이 서명에 실어야 하는 신원 두 줄을 프로필 값으로 맞춘다.
    ///
    /// macOS 는 `com.apple.application-identifier` 로 번들에 든 프로필이 이 앱 것인지
    /// 확인한다. 이것이 없으면 macOS 11 은 프로필을 아예 보지 않고, 다르면 실행할 때
    /// 앱을 죽인다. Xcode 는 이 키와 `com.apple.developer.team-identifier` 를 알아서
    /// 넣어 주는데, 업로더가 손으로 만든 plist 에는 대개 없다.
    ///
    /// **있던 값도 덮어쓴다.** 다른 팀으로 서명돼 있던 빌드를 다시 서명하면 옛 팀의 값이
    /// 남아 있다. 키 단위 대조로는 그것을 못 잡고, 공증까지 통과한 뒤 사용자의 맥에서
    /// 죽는다. 프로필을 넣은 이상 신원은 프로필이 정한다.
    public static func applyingProfileIdentity(
        to plist: Data, from profile: ProvisioningProfile
    ) -> Data {
        guard var dictionary = dictionary(fromPropertyList: plist) else { return plist }
        var changed = false
        if let applicationIdentifier = profile.applicationIdentifier,
           dictionary["com.apple.application-identifier"] as? String != applicationIdentifier {
            dictionary["com.apple.application-identifier"] = applicationIdentifier
            changed = true
        }
        if let team = profile.teamIdentifier,
           dictionary["com.apple.developer.team-identifier"] as? String != team {
            dictionary["com.apple.developer.team-identifier"] = team
            changed = true
        }
        guard changed else { return plist }
        return propertyList(from: dictionary) ?? plist
    }

    /// 프로필이 있어야 하는 권한을 뺀다.
    ///
    /// 업로더가 준 plist 는 안쪽 헬퍼 `.app` 에도 붙는다. 헬퍼에는 프로필이 없으므로
    /// 그 권한을 그대로 실으면 헬퍼가 뜨자마자 macOS 가 죽인다. 헬퍼가 그 권한을 써야
    /// 하는 앱이라면 헬퍼에 자기 프로필이 있어야 하고, 그때는 이 함수를 부르지 않는다.
    public static func removingProfileRequired(from plist: Data) -> Data {
        guard var dictionary = dictionary(fromPropertyList: plist) else { return plist }
        let restricted = EntitlementsPlist.requiringProvisioningProfile(in: dictionary.keys)
        guard !restricted.isEmpty else { return plist }
        for key in restricted { dictionary.removeValue(forKey: key) }
        return propertyList(from: dictionary) ?? plist
    }

    private static func dictionary(fromPropertyList data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any]
    }

    private static func propertyList(from dictionary: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    // MARK: - 번들에서 읽기

    /// 번들에 붙어 있는 권한 목록을 plist 원문 그대로 읽는다.
    ///
    /// 서명이 없는 번들에서는 읽을 것이 없어서 빈 데이터가 나온다. 그건 오류가 아니다.
    /// 권한을 전혀 안 쓰는 앱이 대부분이다.
    public static func read(of bundle: URL) async -> Data {
        let result = await Shell.runDetached(
            "/usr/bin/codesign",
            ["-d", "--entitlements", ":-", "--xml", bundle.path],
            timeout: 60
        )
        guard result.succeeded else { return Data() }
        return Data(result.standardOutput.utf8)
    }

    /// plist 에서 최상위 키만 뽑는다.
    public static func keys(fromPropertyList data: Data) -> [String] {
        guard !data.isEmpty,
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let dictionary = parsed as? [String: Any]
        else {
            return []
        }
        return dictionary.keys.sorted()
    }

    /// 읽어둔 권한을 codesign 에 다시 넘길 파일로 쓴다.
    ///
    /// **다시 넘기지 않으면 권한이 사라진다.** `codesign` 은 재서명할 때 이전 권한을
    /// 물려주지 않는다. 그래서 지금 붙어 있는 것을 그대로 꺼내 파일로 만들어 넘긴다.
    /// 권한이 없으면 nil 을 주고, 그때는 `--entitlements` 없이 서명한다.
    public static func writePropertyList(_ data: Data, to file: URL) -> URL? {
        guard !keys(fromPropertyList: data).isEmpty else { return nil }
        do {
            try data.write(to: file)
            return file
        } catch {
            return nil
        }
    }
}
