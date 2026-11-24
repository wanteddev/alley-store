import AlleyProcess
import AlleyShared
import Foundation
import Testing

@testable import AlleyWorkerCore

@Suite("실패 갈래 나누기")
struct FailureClassificationTests {
    @Test("번들을 찾지 못한 것은 번들 구조 문제다")
    func bundleErrorsAreLayoutProblems() {
        let notFound = AppBundle.BundleError.notFound(directory: URL(fileURLWithPath: "/tmp/x"))
        let ambiguous = AppBundle.BundleError.ambiguous(names: ["A.app", "B.app"])
        #expect(SigningFailureCode.classify(notFound) == .bundleLayoutInvalid)
        #expect(SigningFailureCode.classify(ambiguous) == .bundleLayoutInvalid)
    }

    /// 고칠 것이 앱이 아니라 스토어의 프로필이다 (ADR-0085). entitlements 갈래로
    /// 두면 화면이 "entitlements 를 붙여 다시 시도" 하는 칸을 내미는데, 그것은 헛걸음이다.
    @Test("프로필이 없거나 모자라면 프로필 갈래다")
    func missingProfileIsProfileProblem() {
        let keys = ["com.apple.developer.icloud-services"]
        let errors: [Entitlements.ValidationError] = [
            .missingProfile(bundle: "도구.app", keys: keys),
            .profileDoesNotAllow(bundle: "도구.app", keys: keys, disallowed: keys, details: []),
            .unreadableProfile(bundle: "도구.app", keys: keys),
        ]
        for error in errors {
            #expect(SigningFailureCode.classify(error) == .provisioningProfileRequired)
            #expect(error.profileKeys == keys)
        }
    }

    /// 번들 ID 가 임시값인 앱의 프로필 실패는 번들 ID 를 싣느라 한 겹 싸인다. 갈래는
    /// 그대로여야 한다.
    @Test("번들 ID 를 실은 프로필 실패도 프로필 갈래다")
    func blockedProfileKeepsItsCode() {
        let error = SigningPipeline.ProfileBlocked(
            validation: .missingProfile(
                bundle: "도구.app", keys: ["com.apple.developer.icloud-services"]
            ),
            bundleIdentifier: "com.example.tool"
        )
        #expect(SigningFailureCode.classify(error) == .provisioningProfileRequired)
        #expect(error.description == error.validation.description)
    }

    @Test("Developer ID 로 못 쓰는 권한은 entitlements 갈래다")
    func unsupportedIsEntitlementsProblem() {
        let error = Entitlements.ValidationError.unsupportedForDeveloperID(
            bundle: "도구.app", keys: ["com.apple.developer.applesignin"]
        )
        // 프로필로 풀리지 않는다. 서버가 발급 자리를 내면 안 되므로 키를 싣지 않는다.
        #expect(SigningFailureCode.classify(error) == .entitlementsRejected)
        #expect(error.profileKeys == nil)
    }

    @Test("파이프라인 오류는 자기가 들고 있는 갈래를 그대로 쓴다")
    func pipelineErrorCarriesItsOwnCode() {
        let failed = SigningPipeline.PipelineError.commandFailed(
            step: "서명 검증", code: .unsignedCodeRemains, detail: "남음"
        )
        #expect(SigningFailureCode.classify(failed) == .unsignedCodeRemains)

        let rejected = SigningPipeline.PipelineError.notarizationRejected(detail: "거절")
        #expect(SigningFailureCode.classify(rejected) == .notarizationRejected)
    }

    @Test("아티팩트를 주고받지 못한 것은 다시 해볼 만하다")
    func transferErrorsAreRetriable() {
        let transfer = WorkerClient.ClientError.transfer(action: "내려받기", detail: "curl: 7")
        let code = SigningFailureCode.classify(transfer)
        #expect(code == .transferFailed)
        #expect(code.isRetriable)
    }

    @Test("모르는 오류는 분류하지 못한 것으로 둔다")
    func unrecognizedErrorIsUnknown() {
        struct Odd: Error {}
        #expect(SigningFailureCode.classify(Odd()) == .unknown)
    }

    @Test("시간 초과는 종료 코드로 알아본다")
    func timeoutComesFromExitCode() {
        // Shell 은 제한 시간을 넘긴 프로세스를 죽이고 124 를 돌려준다.
        #expect(SigningPipeline.code(exitCode: 124, otherwise: .codesignFailed) == .timedOut)
        #expect(SigningPipeline.code(exitCode: 1, otherwise: .codesignFailed) == .codesignFailed)
    }

    @Test("codesign 출력에서 identity 문제를 좁힌다")
    func codesignIdentityMarkers() {
        // 여기만 문자열을 본다. 종료 코드로는 나눌 수 없다.
        #expect(
            SigningPipeline.codesignCode(from: "도구.app: no identity found")
                == .signingIdentityUnavailable
        )
        #expect(
            SigningPipeline.codesignCode(
                from: "The specified item could not be found in the keychain."
            ) == .signingIdentityUnavailable
        )
        // 키체인이 잠겨 키에 닿지 못한 것은 번들 문제가 아니다 (이슈 #83).
        #expect(
            SigningPipeline.codesignCode(
                from: "도구.app: replacing existing signature\n도구.app: errSecInternalComponent"
            ) == .signingKeyInaccessible
        )
        #expect(
            SigningPipeline.codesignCode(from: "User interaction is not allowed.")
                == .signingKeyInaccessible
        )
        // 번들 쪽 문제는 identity 와 섞이지 않아야 한다.
        #expect(
            SigningPipeline.codesignCode(from: "resource fork, Finder information, or similar detritus not allowed")
                == .codesignFailed
        )
    }

    @Test("공증은 제출이 접수된 경우에만 거절로 본다")
    func onlyReviewedSubmissionsAreRejections() {
        // 제출 자체가 안 되면 상태가 없다. 앱 내용과 무관한 실패라 다시 해볼 만하다.
        #expect(SigningPipeline.isRejection(nil) == false)
        #expect(SigningPipeline.isRejection(NotarySubmission(json: "{}")) == false)

        let invalid = NotarySubmission(json: #"{"id":"abc","status":"Invalid"}"#)
        #expect(SigningPipeline.isRejection(invalid))
    }
}
