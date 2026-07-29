@testable import SayItBackend
import Testing

struct APITokenDigestTests {
    @Test
    func matchingDigestsAreAccepted() {
        let digest = APITokenDigest.digest("sayit_example_secret")
        #expect(APITokenDigest.matches(digest, digest))
    }

    @Test
    func differentOrTruncatedDigestsAreRejected() {
        let first = APITokenDigest.digest("first")
        let second = APITokenDigest.digest("second")
        #expect(!APITokenDigest.matches(first, second))
        #expect(!APITokenDigest.matches(first, first.dropLast()))
    }
}
