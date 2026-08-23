import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .dashboard

    /// Five tabs, deliberately. A sixth would make iOS fold the overflow into
    /// its own generic "More" list, which buried Alerts two taps deep behind a
    /// screen Cathode does not control. Alerts is reachable from the badged
    /// bell in the dashboard header and from the More screen instead.
    enum Tab: String, Hashable, CaseIterable {
        case dashboard, history, sky, network, more

        var title: String {
            switch self {
            case .dashboard: "Dash"
            case .history: "History"
            case .sky: "Sky"
            case .network: "Network"
            case .more: "More"
            }
        }
        var icon: String {
            switch self {
            case .dashboard: "gauge.open.with.lines.needle.33percent"
            case .history: "chart.xyaxis.line"
            case .sky: "circle.hexagongrid"
            case .network: "wifi.router"
            case .more: "ellipsis.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            DashboardScreen()
                .tabItem { Label(Tab.dashboard.title, systemImage: Tab.dashboard.icon) }
                .tag(Tab.dashboard)
            HistoryScreen()
                .tabItem { Label(Tab.history.title, systemImage: Tab.history.icon) }
                .tag(Tab.history)
            SkyScreen()
                .tabItem { Label(Tab.sky.title, systemImage: Tab.sky.icon) }
                .tag(Tab.sky)
            NetworkScreen()
                .tabItem { Label(Tab.network.title, systemImage: Tab.network.icon) }
                .tag(Tab.network)
            MoreScreen()
                .tabItem { Label(Tab.more.title, systemImage: Tab.more.icon) }
                .tag(Tab.more)
        }
        .tint(.good)
    }
}
