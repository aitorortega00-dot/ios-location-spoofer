import Foundation
import UserNotifications

/// Countdown that starts every time a spoof is applied successfully, so the user knows
/// roughly how long to wait before slower apps pick up the new location.
/// Optionally sends a notification when it ends (useful while waiting in another app).
enum SpoofTimer {
    private static let startKey = "spoofTimerStart"
    private static let minutesKey = "spoofTimerMinutes"
    private static let notifyKey = "spoofTimerNotify"
    private static let notificationId = "spoof-timer-done"

    static let minuteChoices = [1, 2, 3, 5, 10, 15]

    /// Settings → countdown length (default 3 minutes).
    static var minutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: minutesKey)
            return v > 0 ? v : 3
        }
        set { UserDefaults.standard.set(newValue, forKey: minutesKey) }
    }

    /// Settings → notify when the countdown ends (default on).
    static var notifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: notifyKey)
            if !newValue { cancelNotification() }
        }
    }

    static var startDate: Date? {
        UserDefaults.standard.object(forKey: startKey) as? Date
    }

    static var endDate: Date? {
        startDate.map { $0.addingTimeInterval(TimeInterval(minutes * 60)) }
    }

    /// Called when a spoof has just been applied successfully.
    static func start(placeName: String) {
        let now = Date()
        UserDefaults.standard.set(now, forKey: startKey)
        DiagLog.add("[timer] started: \(minutes) min for \(placeName)")
        scheduleNotification(placeName: placeName)
    }

    /// Called when spoofing is disabled.
    static func stop() {
        UserDefaults.standard.removeObject(forKey: startKey)
        cancelNotification()
    }

    /// Seconds left, 0 when finished, nil when no countdown has been started.
    static func remaining(at date: Date = Date()) -> TimeInterval? {
        guard let end = endDate else { return nil }
        return max(0, end.timeIntervalSince(date))
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Notification

    private static func scheduleNotification(placeName: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        guard notifyEnabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                DiagLog.add("[timer] notifications not allowed, countdown only in the app")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "\(minutes) min since the spoof"
            content.body = "\(placeName) has been active for \(minutes) min. Slower apps should have it by now."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
            center.add(UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger))
        }
    }

    private static func cancelNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationId])
        center.removeDeliveredNotifications(withIdentifiers: [notificationId])
    }
}
