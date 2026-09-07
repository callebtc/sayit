import SayItXPC
import Testing

struct ServiceJobTerminationTests {
    @Test func extractsLaunchdProcessID() {
        #expect(ServiceJobTermination.processID(in: "service = {\n\tstate = running\n\tpid = 12345\n}") == 12345)
    }

    @Test func unloadedJobHasNoProcessID() {
        #expect(ServiceJobTermination.processID(in: "service = {\n\tstate = not running\n}") == nil)
        #expect(ServiceJobTermination.processID(in: "\tpid = 0") == nil)
        #expect(ServiceJobTermination.processID(in: "\tpid = 1") == nil)
        #expect(ServiceJobTermination.processID(in: "\tpid = invalid") == nil)
    }
}
