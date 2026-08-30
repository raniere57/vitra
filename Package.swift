// swift-tools-version: 6.0
import Foundation
import PackageDescription

// libghostty-vt is vendored, not fetched by SwiftPM: its C API is explicitly
// unstable, so it is pinned to a commit and built by scripts/vendor-ghostty-vt.sh.
// The archive is linked by absolute path because passing -lghostty-vt would let
// the linker pick the .dylib that sits beside it; Vitra ships one static binary.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyArchive = "\(packageDirectory)/vendor/ghostty-vt/lib/libghostty-vt.a"

let package = Package(
    name: "Vitra",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CGhosttyVT",
            publicHeadersPath: "include",
            linkerSettings: [.unsafeFlags([ghosttyArchive])]
        ),
        .target(name: "VitraCore"),
        .target(name: "VitraGhostty", dependencies: ["CGhosttyVT", "VitraCore"]),
        .target(
            name: "VitraRender",
            dependencies: ["VitraCore"],
            plugins: ["MetalShaderCompiler"]
        ),
        .plugin(name: "MetalShaderCompiler", capability: .buildTool()),
        .executableTarget(name: "vitra-spike", dependencies: ["VitraCore", "VitraGhostty", "VitraRender"]),
        .executableTarget(
            name: "VitraApp",
            dependencies: ["VitraCore", "VitraGhostty", "VitraRender"]
        ),
        .testTarget(name: "VitraCoreTests", dependencies: ["VitraCore"]),
        .testTarget(name: "VitraGhosttyTests", dependencies: ["VitraGhostty", "VitraCore"]),
        .testTarget(name: "VitraRenderTests", dependencies: ["VitraRender", "VitraCore"]),
        .testTarget(name: "VitraAppTests", dependencies: ["VitraApp", "VitraCore"]),
    ]
)
