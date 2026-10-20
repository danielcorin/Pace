enum PacePanelScope: String, CaseIterable, Identifiable {
    case clipboard
    case snippets
    case actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .snippets: return "Snippets"
        case .actions: return "Actions"
        }
    }

    var systemImage: String {
        switch self {
        case .clipboard: return "clipboard"
        case .snippets: return "text.quote"
        case .actions: return "bolt"
        }
    }
}
