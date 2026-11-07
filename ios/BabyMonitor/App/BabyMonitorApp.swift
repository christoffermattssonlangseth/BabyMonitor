import SwiftUI
import UIKit
import UserNotifications

@main
struct BabyMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// While the app is on screen it shows its own banner and sound,
    /// so notifications only go to Notification Center.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list])
    }
}

enum Role: String {
    case parent
    case baby
}

struct Session {
    let role: Role
    let password: String
    let name: String
}

struct RootView: View {
    @State private var session: Session?

    var body: some View {
        if let session {
            switch session.role {
            case .baby:
                BabyView(password: session.password, name: session.name) { self.session = nil }
            case .parent:
                ParentView(password: session.password, name: session.name) { self.session = nil }
            }
        } else {
            SetupView { self.session = $0 }
        }
    }
}
