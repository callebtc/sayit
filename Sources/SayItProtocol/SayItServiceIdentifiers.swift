import Foundation

public enum SayItServiceIdentifiers {
    public static let appGroup = "group.sh.sayit.mac"
    public static let teamIdentifier = "D7AHD3GLH6"
#if DEBUG || SAYIT_LOCAL_BUILD
    public static let machService = "sh.sayit.mac.agent.debug"
#else
    public static let machService = "group.sh.sayit.mac.agent"
#endif
#if DEBUG || SAYIT_LOCAL_BUILD
    public static let selectionMachService = "sh.sayit.mac.selection.debug"
#else
    public static let selectionMachService = "sh.sayit.mac.selection.xpc"
#endif
    public static let launchAgentPlist = "sh.sayit.mac.agent.plist"
    public static let applicationBundle = "sh.sayit.mac"
    public static let agentBundle = "sh.sayit.mac.agent"
    public static let selectionAgentBundle = "sh.sayit.mac.selection-helper"
    public static let commandLineBundle = "sh.sayit.mac.cli"
    public static let trustedClientBundleIdentifiers = [
        applicationBundle,
        commandLineBundle
    ]
}
