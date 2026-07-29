import Foundation

public enum SayItServiceIdentifiers {
    public static let appGroup = "group.com.sayit.mac"
    public static let machService = "group.com.sayit.mac.agent"
    public static let launchAgentPlist = "com.sayit.mac.agent.plist"
    public static let applicationBundle = "com.sayit.mac"
    public static let agentBundle = "com.sayit.mac.agent"
    public static let commandLineBundle = "com.sayit.mac.cli"
    public static let clientEntitlement = "com.sayit.client"
    public static let trustedClientBundleIdentifiers = [
        applicationBundle,
        commandLineBundle
    ]
}
