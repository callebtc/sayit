import Testing
@testable import SayItCore

@Suite("Diagnostic redaction")
struct DiagnosticRecorderTests {
    @Test("Only stable allowlisted codes are accepted")
    func safeCodes() {
        #expect(DiagnosticRecorder.isSafeCode("model.load_failed"))
        #expect(DiagnosticRecorder.isSafeCode("download_checksum_42"))
        #expect(!DiagnosticRecorder.isSafeCode("Copied text: private words"))
        #expect(!DiagnosticRecorder.isSafeCode("/local/path/model"))
        #expect(!DiagnosticRecorder.isSafeCode("TOKEN=secret"))
    }
}
