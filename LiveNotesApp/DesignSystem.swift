import SwiftUI

enum LiveNotesStyle {
    static let background = Color(red: 0.965, green: 0.957, blue: 0.937)
    static let surface = Color(red: 0.992, green: 0.988, blue: 0.973)
    static let sidebar = Color(red: 0.934, green: 0.928, blue: 0.906)
    static let graphite = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let secondary = Color(red: 0.42, green: 0.42, blue: 0.44)
    static let line = Color.black.opacity(0.10)
    static let recording = Color(red: 0.80, green: 0.12, blue: 0.10)
    static let liveBlue = Color(red: 0.16, green: 0.36, blue: 0.78)
    static let amber = Color(red: 0.72, green: 0.42, blue: 0.12)
    static let saved = Color(red: 0.18, green: 0.48, blue: 0.28)
}

extension View {
    func softPanel() -> some View {
        background(LiveNotesStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LiveNotesStyle.line)
            )
    }
}
