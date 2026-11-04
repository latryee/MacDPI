// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDPI",
    platforms: [.macOS(.v12)],
    products: [.library(name: "MacDPICore", targets: ["MacDPICore"]),
               .executable(name: "macdpi", targets: ["MacDPICLI"])],
    targets: [
        .target(name: "MacDPICore", path: "MacDPI/Core"),
        .executableTarget(name: "MacDPICLI", dependencies: ["MacDPICore"], path: "Tools/MacDPICLI"),
        .testTarget(name: "MacDPICoreTests", dependencies: ["MacDPICore"], path: "Tests/MacDPICoreTests")
    ]
)
