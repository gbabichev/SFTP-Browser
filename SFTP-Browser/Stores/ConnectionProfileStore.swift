//
//  ConnectionProfileStore.swift
//  SFTP-Browser
//
//  Created by OpenAI on 4/27/26.
//

import Foundation

struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var remotePath: String
    var updatedAt: Date

    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    var detailText: String {
        "\(username)@\(host):\(port)  \(remotePath)"
    }
}

struct ConnectionProfileStore: Sendable {
    private let defaultsKey = "connection.profiles"

    func profiles() -> [ConnectionProfile] {
        load().sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func save(_ profile: ConnectionProfile) {
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        write(profiles)
    }

    func delete(_ profile: ConnectionProfile) {
        write(load().filter { $0.id != profile.id })
    }

    private func load() -> [ConnectionProfile] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return []
        }

        return (try? JSONDecoder().decode([ConnectionProfile].self, from: data)) ?? []
    }

    private func write(_ profiles: [ConnectionProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
