import Foundation

public enum SayItSkill {
    public static var bundledURL: URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: SayItSkillBundleToken.self)
        #endif
        return bundle.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "sayit"
        ) ?? bundle.url(forResource: "SKILL", withExtension: "md")
    }
}

private final class SayItSkillBundleToken {}
