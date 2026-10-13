import PackagePlugin
import Foundation

@main
struct BuildIdentity: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        [.prebuildCommand(displayName: "Stamp gob.lin build identity",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [context.package.directoryURL.appendingPathComponent("scripts/build-identity.sh").path,
                        context.package.directoryURL.path, context.pluginWorkDirectoryURL.path],
            outputFilesDirectory: context.pluginWorkDirectoryURL)]
    }
}
