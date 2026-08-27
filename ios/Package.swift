// swift-tools-version: 5.9
// SPDX-License-Identifier: MIT
import PackageDescription

// Amphora's iOS target had NO build manifest, which is why "neither target compiles"
// understated the problem: there was no project to compile. This is that project.
//
// No external dependencies, deliberately. The wire protocol is spoken directly
// (create/head/append/terminate) and TUSKitTransport does not import TUSKit — its
// value was tus 1.0 request construction, which this target does itself.
//
// macOS is declared alongside iOS so the package can be built and tested from the
// command line without Xcode. That is not a shipping target; it is what makes the
// state machine verifiable in CI.
let package = Package(
    name: "Amphora",
    // macOS 14, not 13: `URLSessionTask.cancelByProducingResumeData()` and
    // `uploadTaskResumeData` — the iOS 17 resumable-upload APIs this target is built
    // around — landed on macOS in 14. Declaring 13 would force `if #available` guards
    // onto a platform that never ships, adding dead branches to satisfy a build host.
    platforms: [.iOS(.v15), .macOS(.v14)],
    products: [
        .library(name: "Amphora", targets: ["Amphora"]),
    ],
    targets: [
        .target(
            name: "Amphora",
            path: "Sources/Amphora",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AmphoraPathTests",
            dependencies: ["Amphora"],
            path: "Tests/AmphoraTests"
        ),
        .executableTarget(
            name: "AmphoraTusdIntegration",
            dependencies: ["Amphora"],
            path: "Tests/AmphoraTusdIntegration"
        ),
    ]
)
