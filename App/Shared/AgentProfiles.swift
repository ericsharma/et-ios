import SwiftUI

// PLAN-multi-agent M1: which profile a session runs, and its mark. Stays
// when AgentProfilesStub.swift goes.

extension AgentProfile {
    static func profile(id: String) -> AgentProfile? {
        agentProfiles().first { $0.id == id }
    }

    /// The first profile whose program runs here, or whose id is in the
    /// command, the name or the title. A window that runs an agent over ssh
    /// shows "ssh", so the name and title matter too.
    static func matching(currentCommand: String = "", command: String = "", name: String, title: String) -> AgentProfile? {
        agentProfiles().first { profile in
            profile.processes.contains(currentCommand)
                || command.localizedCaseInsensitiveContains(profile.id)
                || name.localizedCaseInsensitiveContains(profile.id)
                || title.localizedCaseInsensitiveContains(profile.id)
        }
    }

    /// "Claude" for "Claude Code", "Gemini" for "Gemini CLI".
    var shortName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Catppuccin Mocha (D8); a user profile's mark is on overlay.
    var accentColor: Color {
        switch accent {
        case "peach": Color(red: 0xFA / 255, green: 0xB3 / 255, blue: 0x87 / 255)
        case "green": Color(red: 0xA6 / 255, green: 0xE3 / 255, blue: 0xA1 / 255)
        case "blue": Color(red: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255)
        case "mauve": Color(red: 0xCB / 255, green: 0xA6 / 255, blue: 0xF7 / 255)
        default: Color(red: 0x6C / 255, green: 0x70 / 255, blue: 0x86 / 255)
        }
    }
}

/// An agent's one letter on its accent color (D8: no vendor logos).
struct AgentMark: View {
    let profile: AgentProfile
    var size: CGFloat = 16

    var body: some View {
        Text(profile.mark)
            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x2E / 255))
            .frame(width: size, height: size)
            .background(profile.accentColor, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityLabel(profile.name)
            .help(profile.name)
    }
}
