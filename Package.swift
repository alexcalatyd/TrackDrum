// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackDrum",
    platforms: [.macOS(.v13)],
    targets: [
        // Puente en C: MultitouchSupport (dlopen), motor háptico, tapa y acelerómetro.
        .target(
            name: "CMultitouch",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "TrackDrum",
            dependencies: ["CMultitouch"],
            resources: [.copy("Web")]
        ),
    ]
)
