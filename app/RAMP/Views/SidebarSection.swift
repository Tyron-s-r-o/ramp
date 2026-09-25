import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case services, vhosts, php, database, logs, settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .services: "Služby"
        case .vhosts: "Vhosty"
        case .php: "PHP"
        case .database: "Databáza"
        case .logs: "Logy"
        case .settings: "Nastavenia"
        }
    }

    var systemImage: String {
        switch self {
        case .services: "server.rack"
        case .vhosts: "globe"
        case .php: "chevron.left.forwardslash.chevron.right"
        case .database: "cylinder.split.1x2"
        case .logs: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        }
    }
}
