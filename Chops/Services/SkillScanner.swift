import Foundation
import SwiftData

@Observable
final class SkillScanner {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Project-level paths to probe inside each project directory
    private static let projectProbes: [(subpath: String, tool: ToolSource)] = [
        (".claude/skills", .claude),
        (".cursor/skills", .cursor),
        (".cursor/rules", .cursor),
        (".codex", .codex),
        (".windsurf/rules", .windsurf),
        (".github", .copilot),
        (".config/amp", .amp),
    ]

    func scanAll() {
        for tool in ToolSource.allCases where tool != .custom {
            scanTool(tool)
        }
        let customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        for path in customPaths {
            scanCustomDirectory(URL(fileURLWithPath: path))
        }
    }

    /// Scans a custom directory by iterating its subdirectories (projects)
    /// and probing each for tool-specific skill locations.
    private func scanCustomDirectory(_ directory: URL) {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for project in projects {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: project.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            for probe in Self.projectProbes {
                let probePath = project.appendingPathComponent(probe.subpath)
                guard fm.fileExists(atPath: probePath.path) else { continue }

                if probe.tool == .copilot {
                    // Copilot: single file
                    let file = probePath.appendingPathComponent("copilot-instructions.md")
                    if fm.fileExists(atPath: file.path) {
                        upsertSkill(at: file, toolSource: .copilot, isDirectory: false, isGlobal: false)
                    }
                } else {
                    scanDirectory(probePath, toolSource: probe.tool, isGlobal: false)
                }
            }
        }
    }

    func scanTool(_ tool: ToolSource) {
        for path in tool.globalPaths {
            let url = URL(fileURLWithPath: path)
            scanDirectory(url, toolSource: tool, isGlobal: true)
        }
    }

    private func scanDirectory(_ directory: URL, toolSource: ToolSource, isGlobal: Bool = true) {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir) else { return }

        // Single-file tools like Codex: look for AGENTS.md directly in the directory
        if toolSource == .codex || toolSource == .amp {
            let agentsMD = directory.appendingPathComponent("AGENTS.md")
            if fm.fileExists(atPath: agentsMD.path) {
                upsertSkill(at: agentsMD, toolSource: toolSource, isDirectory: false, isGlobal: isGlobal)
            }
            // Scan subdirectories for skills (SKILL.md or AGENTS.md)
            // The official skills CLI installs SKILL.md into subdirectories here
            let scanDirs = [directory, directory.appendingPathComponent("skills")]
            for scanDir in scanDirs {
                guard let contents = try? fm.contentsOfDirectory(
                    at: scanDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for item in contents {
                    var itemIsDir: ObjCBool = false
                    fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)
                    if itemIsDir.boolValue {
                        let skillFile = item.appendingPathComponent("SKILL.md")
                        let agentsFile = item.appendingPathComponent("AGENTS.md")
                        if fm.fileExists(atPath: skillFile.path) {
                            upsertSkill(at: skillFile, toolSource: toolSource, isDirectory: true, isGlobal: isGlobal)
                        } else if fm.fileExists(atPath: agentsFile.path) {
                            upsertSkill(at: agentsFile, toolSource: toolSource, isDirectory: true, isGlobal: isGlobal)
                        }
                    }
                }
            }
            return
        }

        guard isDir.boolValue else { return }

        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            var itemIsDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)

            if itemIsDir.boolValue {
                // Directory-based skill — look for SKILL.md or AGENTS.md inside
                let skillFile = item.appendingPathComponent("SKILL.md")
                let agentsFile = item.appendingPathComponent("AGENTS.md")

                if fm.fileExists(atPath: skillFile.path) {
                    upsertSkill(at: skillFile, toolSource: toolSource, isDirectory: true, isGlobal: isGlobal)
                } else if fm.fileExists(atPath: agentsFile.path) {
                    upsertSkill(at: agentsFile, toolSource: toolSource, isDirectory: true, isGlobal: isGlobal)
                }
            } else if item.pathExtension == "md" || item.pathExtension == "mdc" {
                upsertSkill(at: item, toolSource: toolSource, isDirectory: false, isGlobal: isGlobal)
            }
        }
    }

    private func upsertSkill(at fileURL: URL, toolSource: ToolSource, isDirectory: Bool, isGlobal: Bool = true) {
        let fm = FileManager.default
        let path = fileURL.path
        let resolved = fileURL.resolvingSymlinksInPath().path

        guard let parsed = SkillParser.parse(fileURL: fileURL, toolSource: toolSource) else { return }

        let attrs = try? fm.attributesOfItem(atPath: resolved)
        let modDate = (attrs?[.modificationDate] as? Date) ?? .now
        let fileSize = (attrs?[.size] as? Int) ?? 0

        let name: String
        if !parsed.name.isEmpty {
            name = parsed.name
        } else if isDirectory {
            name = fileURL.deletingLastPathComponent().lastPathComponent
        } else {
            name = fileURL.deletingPathExtension().lastPathComponent
        }

        // Dedup: look up by resolved path first
        let predicate = #Predicate<Skill> { $0.resolvedPath == resolved }
        let descriptor = FetchDescriptor<Skill>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            // Same physical file — merge this tool/path into the existing entry
            existing.content = parsed.content
            existing.name = name
            existing.skillDescription = parsed.description
            existing.frontmatter = parsed.frontmatter
            existing.fileModifiedDate = modDate
            existing.fileSize = fileSize
            existing.addInstallation(path: path, tool: toolSource)
        } else {
            let skill = Skill(
                filePath: path,
                toolSource: toolSource,
                isDirectory: isDirectory,
                name: name,
                skillDescription: parsed.description,
                content: parsed.content,
                frontmatter: parsed.frontmatter,
                fileModifiedDate: modDate,
                fileSize: fileSize,
                isGlobal: isGlobal,
                resolvedPath: resolved
            )
            modelContext.insert(skill)
        }

        try? modelContext.save()
    }

    // MARK: - Remote Server Scanning

    func syncAllRemoteServers() async {
        let descriptor = FetchDescriptor<RemoteServer>()
        guard let servers = try? modelContext.fetch(descriptor) else { return }
        for server in servers {
            await scanRemoteServer(server)
        }
    }

    /// Scans a remote server for skills. Sets lastSyncError on failure.
    func scanRemoteServer(_ server: RemoteServer) async {
        do {
            let remoteSkills = try await SSHService.findSkills(server)
            var foundPaths = Set<String>()

            for (path, content) in remoteSkills {
                let resolvedPath = "remote://\(server.id)/\(path)"
                foundPaths.insert(resolvedPath)

                let parsed = FrontmatterParser.parse(content)
                let name: String
                if !parsed.name.isEmpty {
                    name = parsed.name
                } else {
                    // Derive name from parent directory
                    let components = path.components(separatedBy: "/")
                    let skillDirIndex = components.lastIndex(of: "SKILL.md").map { components.index(before: $0) }
                    name = skillDirIndex.map { components[$0] } ?? "Unknown"
                }

                let predicate = #Predicate<Skill> { $0.resolvedPath == resolvedPath }
                let fetchDescriptor = FetchDescriptor<Skill>(predicate: predicate)

                if let existing = try? modelContext.fetch(fetchDescriptor).first {
                    existing.content = parsed.content
                    existing.name = name
                    existing.skillDescription = parsed.description
                    existing.frontmatter = parsed.frontmatter
                } else {
                    let skill = Skill(
                        filePath: resolvedPath,
                        toolSource: .openclaw,
                        isDirectory: true,
                        name: name,
                        skillDescription: parsed.description,
                        content: parsed.content,
                        frontmatter: parsed.frontmatter,
                        isGlobal: true,
                        resolvedPath: resolvedPath
                    )
                    skill.remoteServer = server
                    skill.remotePath = path
                    modelContext.insert(skill)
                }
            }

            // Remove skills that no longer exist on the server
            let serverID = server.id
            let remotePredicate = #Predicate<Skill> { $0.resolvedPath.starts(with: "remote://") }
            if let existingRemoteSkills = try? modelContext.fetch(FetchDescriptor<Skill>(predicate: remotePredicate)) {
                for skill in existingRemoteSkills {
                    guard skill.remoteServer?.id == serverID else { continue }
                    if !foundPaths.contains(skill.resolvedPath) {
                        modelContext.delete(skill)
                    }
                }
            }

            server.lastSyncDate = .now
            server.lastSyncError = nil
            try? modelContext.save()
        } catch {
            server.lastSyncError = error.localizedDescription
            try? modelContext.save()
        }
    }

    func removeDeletedSkills() {
        let descriptor = FetchDescriptor<Skill>()
        guard let skills = try? modelContext.fetch(descriptor) else { return }
        let fm = FileManager.default

        for skill in skills {
            // Remove orphaned remote skills (server was deleted)
            if skill.resolvedPath.hasPrefix("remote://") && skill.remoteServer == nil {
                modelContext.delete(skill)
                continue
            }

            // Remote skills are managed by scanRemoteServer(), skip here
            if skill.isRemote { continue }

            // Remove paths that no longer exist
            let validPaths = skill.installedPaths.filter { fm.fileExists(atPath: $0) }
            if validPaths.isEmpty {
                modelContext.delete(skill)
            } else {
                skill.installedPaths = validPaths
                // Update primary filePath if it was deleted
                if !fm.fileExists(atPath: skill.filePath), let first = validPaths.first {
                    skill.filePath = first
                }
            }
        }
        try? modelContext.save()
    }
}
