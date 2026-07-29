import Foundation

extension TimeInterval {
    var formattedDuration: String {
        Duration.seconds(max(self, 0)).formatted(
            .time(pattern: .minuteSecond(padMinuteToLength: 2))
        )
    }
}
