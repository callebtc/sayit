import Foundation

public enum SayItServiceIdentifiers {
    public static let appGroup = "group.sh.sayit.mac"
#if DEBUG || SAYIT_LOCAL_BUILD
    public static let machService = "sh.sayit.mac.agent.debug"
#else
    public static let machService = "group.sh.sayit.mac.agent"
#endif
#if DEBUG || SAYIT_LOCAL_BUILD
    public static let selectionMachService = "sh.sayit.mac.selection.debug"
#else
    public static let selectionMachService = "group.sh.sayit.mac.selection"
#endif
    public static let launchAgentPlist = "sh.sayit.mac.agent.plist"
    public static let selectionLaunchAgentPlist =
        "sh.sayit.mac.selection.plist"
    public static let applicationBundle = "sh.sayit.mac"
    public static let agentBundle = "sh.sayit.mac.agent"
    public static let selectionAgentBundle = "sh.sayit.mac.selection"
    public static let commandLineBundle = "sh.sayit.mac.cli"
    public static let clientEntitlement = "sh.sayit.client"
    public static let trustedClientBundleIdentifiers = [
        applicationBundle,
        commandLineBundle
    ]
}
