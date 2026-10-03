import Testing
import Foundation

// #4464: Overture crashed on every launch once #4458 moved the freeze report off the main actor. The
// report writes UserDefaults, UserDefaults posts `didChangeNotification` synchronously on the WRITING
// thread, and AppDelegate observed it with a selector into a main actor method, so Swift's isolation check
// trapped. Which thread posts is decided by whoever writes a setting, anywhere in the app, so the observer
// is what has to be safe, not each writer.
@Suite("A notification any thread can post reaches main actor code on the main queue (#4464)")
struct MainQueueNotificationTests {

    @MainActor
    @Test func aPostFromABackgroundThreadRunsTheActionOnTheMainThread() async {
        let center = NotificationCenter()
        let name = Notification.Name("MainQueueNotificationTests.background")
        var ranOnMain: [Bool] = []
        let token = MainQueueNotification.observe(name, in: center) { ranOnMain.append(Thread.isMainThread) }
        defer { center.removeObserver(token) }

        let postedOnMain: Bool = await withCheckedContinuation { done in
            Thread.detachNewThread {
                center.post(name: name, object: nil)
                done.resume(returning: Thread.isMainThread)
            }
        }
        #expect(!postedOnMain, "the post must come from a background thread, or this proves nothing")

        let ran = await waitUntil("the observer to run after a background post") { !ranOnMain.isEmpty }
        #expect(ran, "the action never ran, so where it ran says nothing")
        #expect(ranOnMain == [true], "the action ran off the main thread: \(ranOnMain)")
    }

    // The positive control in the same fixture (L159): a post from the main thread also runs the action.
    @MainActor
    @Test func aPostFromTheMainThreadRunsTheActionToo() async {
        let center = NotificationCenter()
        let name = Notification.Name("MainQueueNotificationTests.main")
        var runs = 0
        let token = MainQueueNotification.observe(name, in: center) { runs += 1 }
        defer { center.removeObserver(token) }
        center.post(name: name, object: nil)
        let ran = await waitUntil("the observer to run after a main thread post") { runs == 1 }
        #expect(ran)
    }

    // The class (L30): no app code observes the settings change notification through a selector, which is
    // delivered on whatever thread wrote the setting. Comments are stripped so prose about the defect
    // cannot trip or satisfy it (L103).
    @Test func noAppSourceObservesASettingsChangeThroughASelector() throws {
        let offenders = AppSourceWalk.appFiles().flatMap { file -> [String] in
            let lines = SwiftSource.scannableLines(in: file.text)
            return lines.indices.compactMap { i in
                guard lines[i].code.contains("UserDefaults.didChangeNotification") else { return nil }
                let window = lines[max(0, i - 2)...i].map { $0.code }.joined(separator: " ")
                guard window.contains("selector:") else { return nil }
                return "\(file.name):\(lines[i].line)"
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }
}
