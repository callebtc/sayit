import Foundation

public enum SayItServiceIdentifiers {
    public static let appGroup = "group.sh.sayit.mac"
    public static let teamIdentifier = "D7AHD3GLH6"
#if SAYIT_MODEL_AUDIT_BUILD
    public static let machService = "sh.sayit.mac.agent.model-audit"
#elseif DEBUG || SAYIT_LOCAL_BUILD
    public static let machService = "sh.sayit.mac.agent.debug"
#else
    public static let machService = "group.sh.sayit.mac.agent"
#endif
#if SAYIT_MODEL_AUDIT_BUILD
    public static let selectionMachService = "sh.sayit.mac.selection.model-audit"
#elseif DEBUG || SAYIT_LOCAL_BUILD
    public static let selectionMachService = "sh.sayit.mac.selection.debug"
#else
    public static let selectionMachService = "sh.sayit.mac.selection.xpc"
#endif
    public static let launchAgentPlist = "sh.sayit.mac.agent.plist"
#if SAYIT_MODEL_AUDIT_BUILD
    public static let applicationBundle = "sh.sayit.mac.model-audit"
#elseif DEBUG || SAYIT_LOCAL_BUILD
    public static let applicationBundle = "sh.sayit.mac.local"
#else
    public static let applicationBundle = "sh.sayit.mac"
#endif
    public static let agentBundle = "sh.sayit.mac.agent"
#if SAYIT_MODEL_AUDIT_BUILD
    public static let selectionAgentBundle = "sh.sayit.mac.selection-helper.model-audit"
#elseif DEBUG || SAYIT_LOCAL_BUILD
    public static let selectionAgentBundle = "sh.sayit.mac.selection-helper.local"
#else
    public static let selectionAgentBundle = "sh.sayit.mac.selection-helper"
#endif
    public static let commandLineBundle = "sh.sayit.mac.cli"
    public static let trustedClientBundleIdentifiers = [
        applicationBundle,
        commandLineBundle
    ]
}
