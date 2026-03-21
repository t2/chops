import SwiftData
import Foundation

@Model
final class RemoteServer {
    @Attribute(.unique) var id: String
    var label: String
    var host: String
    var port: Int
    var username: String
    var skillsBasePath: String
    var sshKeyPath: String?
    var lastSyncDate: Date?
    var lastSyncError: String?

    @Relationship(deleteRule: .cascade, inverse: \Skill.remoteServer)
    var skills: [Skill]

    init(
        label: String,
        host: String,
        port: Int = 22,
        username: String,
        skillsBasePath: String
    ) {
        self.id = UUID().uuidString
        self.label = label
        self.host = host
        self.port = port
        self.username = username
        self.skillsBasePath = skillsBasePath
        self.skills = []
    }

    var sshDestination: String {
        "\(username)@\(host)"
    }

    var isOpenClaw: Bool {
        skillsBasePath.contains("openclaw")
    }
}
