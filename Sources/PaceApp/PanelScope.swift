enum PacePanelScope: String, CaseIterable, Identifiable {
    case clipboard
    case snippets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .snippets: return "Snippets"
        }
    }

    var systemImage: String {
        switch self {
        case .clipboard: return "clipboard"
        case .snippets: return "text.quote"
        }
    }
}
