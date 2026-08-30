import Foundation
import PackagePlugin

/// Compiles a target's `.metal` sources into `default.metallib`.
///
/// Xcode does this on its own; `swift build` does not, it only copies the source
/// into the resource bundle. Compiling the shader from source at launch costs
/// ~460 ms on an M1, which is far too much for a terminal that is supposed to
/// open instantly, so it is compiled at build time instead.
@main
struct MetalShaderCompiler: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        let shaders = target.sourceFiles
            .map(\.url)
            .filter { $0.pathExtension == "metal" }
        guard !shaders.isEmpty else { return [] }

        let library = context.pluginWorkDirectoryURL.appending(path: "default.metallib")

        return [
            .buildCommand(
                displayName: "Compiling Metal shaders for \(target.name)",
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["metal", "-O2", "-o", library.path(percentEncoded: false)]
                    + shaders.map { $0.path(percentEncoded: false) },
                inputFiles: shaders,
                outputFiles: [library]
            ),
        ]
    }
}
