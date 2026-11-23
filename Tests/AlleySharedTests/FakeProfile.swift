import Foundation

/// 프로비저닝 프로필 흉내.
///
/// 진짜 프로필은 CMS 서명 안에 XML plist 가 그대로 들어 있다. 우리는 그 plist 만 읽으므로
/// 앞뒤에 아무 바이트나 두르고 가운데 plist 를 넣으면 같은 모양이 된다. 서명이 맞는지는
/// macOS 가 볼 일이고 여기서는 확인하지 않는다.
enum FakeProfile {
    static func make(
        allowing keys: [String],
        team: String = "TEAM123456",
        bundleID: String = "com.example.tool",
        expires: String = "2044-11-23T10:30:00Z"
    ) -> Data {
        var entitlements = keys.map { "<key>\($0)</key><true/>" }
        if !keys.contains("com.apple.application-identifier") {
            entitlements.append(
                "<key>com.apple.application-identifier</key><string>\(team).\(bundleID)</string>"
            )
        }
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            <key>Name</key><string>Alley \(bundleID)</string>
            <key>UUID</key><string>00000000-0000-0000-0000-000000000001</string>
            <key>TeamIdentifier</key><array><string>\(team)</string></array>
            <key>ExpirationDate</key><date>\(expires)</date>
            <key>Entitlements</key><dict>\(entitlements.joined())</dict>
            </dict>
            </plist>
            """
        // CMS 껍데기 대신. DER SEQUENCE 머리처럼 보이는 바이트와 서명 자리.
        return Data([0x30, 0x82, 0x2F, 0x1A, 0x06, 0x09]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00, 0x10])
    }
}
