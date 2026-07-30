import Foundation

public enum SayItServiceIdentifiers {
    public static let appGroup = "group.sh.sayit.mac"
#if DEBUG || SAYIT_LOCAL_BUILD
    public static let machService = "sh.sayit.mac.agent.debug"
#else
    public static let machService = "group.sh.sayit.mac.agent"
#endif
    public static let launchAgentPlist = "sh.sayit.mac.agent.plist"
    public static let applicationBundle = "sh.sayit.mac"
    public static let agentBundle = "sh.sayit.mac.agent"
    public static let commandLineBundle = "sh.sayit.mac.cli"
    public static let clientEntitlement = "sh.sayit.client"
    public static let trustedClientBundleIdentifiers = [
        applicationBundle,
        commandLineBundle
    ]
}
