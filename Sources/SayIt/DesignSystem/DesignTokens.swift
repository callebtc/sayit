import SwiftUI

enum DesignTokens {
    static let popoverWidth: Double = 360
    static let compactSpacing: Double = 8
    static let standardSpacing: Double = 12
    static let generousSpacing: Double = 16
    static let minimumControlSize: Double = 28
    static let ribbonHeight: Double = 42
    static let cardCornerRadius: Double = 10
    static let rowCornerRadius: Double = 6
    static let onboardingCardWidth: Double = 420
    static let quickAnimation = Animation.easeOut(duration: 0.14)
    static let smoothAnimation = Animation.smooth(duration: 0.3)
    static let springAnimation = Animation.spring(response: 0.32, dampingFraction: 0.72)
}
