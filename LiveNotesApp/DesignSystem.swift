import SwiftUI

enum LiveNotesStyle {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let sidebar = Color(red: 0.950, green: 0.948, blue: 0.936)
    static let graphite = Color.primary
    static let secondary = Color.secondary
    static let line = Color(nsColor: .separatorColor).opacity(0.68)
    static let recording = Color(red: 0.760, green: 0.105, blue: 0.090)
    static let liveBlue = Color.accentColor
    static let amber = Color(red: 0.720, green: 0.440, blue: 0.145)
    static let saved = Color(red: 0.145, green: 0.455, blue: 0.280)
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
