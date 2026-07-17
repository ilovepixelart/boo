// Every cross-object notification name in one place; the payload contracts
// are documented at the posting sites.

import Foundation

extension Notification.Name {
    static let themeChanged = Notification.Name("BooThemeChanged")
    static let booRecordingStarted = Notification.Name("BooRecordingStarted")
    static let booRecordingStopped = Notification.Name("BooRecordingStopped")
    static let opacityChanged = Notification.Name("BooOpacityChanged")
    static let autoTypeChanged = Notification.Name("BooAutoTypeChanged")
}
