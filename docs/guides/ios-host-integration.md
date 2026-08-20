# iOS host integration

> **Status:** Draft · **Updated:** 2026-08-19 · **Owner:** Daniel DeKerlegand

Two call sites, both mandatory.

```swift
// AppDelegate.swift

func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    // Before anything else. iOS may have relaunched this process *specifically* to deliver
    // background-session events; if the session and delegate do not exist when those events are
    // replayed, they are lost and in-flight uploads stall with no error.
    Task {
        await AmphoraUploader.shared.configure(store: SQLiteUploadStore.default)
        let report = await AmphoraUploader.shared.ready()
        // report.adopted   — still transferring; re-attached without restarting
        // report.recovered — orphaned but resumed from the server's offset
    }
    return true
}

func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    // Not optional. Fail to invoke this handler and iOS first deprioritises, then stops,
    // relaunching the app for background events — uploads quietly stop progressing.
    Task {
        await AmphoraUploader.shared.handleBackgroundEvents(
            identifier: identifier, completionHandler: completionHandler
        )
    }
}
```

Info.plist needs no `UIBackgroundModes` entry for this. Background `URLSession` transfers are
managed by the system daemon, not by app background execution — a common misconfiguration is
adding `fetch`/`processing` modes and concluding they are what makes uploads work.
