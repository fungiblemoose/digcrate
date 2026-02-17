import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case library = "Library"
    case plan = "Plan Set"
    case sets = "Sets"
    case gaps = "Gaps"
    case discover = "Discover"
    case export = "Export"

    var id: String { rawValue }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: SidebarItem? = .library

    var body: some View {
        NavigationSplitView {
            ZStack {
                VisualEffectGlass(material: .sidebar, blendingMode: .withinWindow)
                .ignoresSafeArea()

                List(SidebarItem.allCases, selection: $selection) { item in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: item))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 22)
                        Text(item.rawValue)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .tag(item)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.06))
            }
            .navigationTitle("DeepCrate")
        } detail: {
            ZStack {
                VisualEffectGlass(material: .underWindowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [Color.blue.opacity(0.08), Color.white.opacity(0.06), Color.cyan.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 460, height: 460)
                    .blur(radius: 72)
                    .offset(x: -260, y: -220)

                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 560, height: 560)
                    .blur(radius: 96)
                    .offset(x: 300, y: 260)

                Group {
                    switch selection ?? .library {
                    case .library:
                        LibraryView()
                    case .plan:
                        PlanView()
                    case .sets:
                        SetsView()
                    case .gaps:
                        GapsView()
                    case .discover:
                        DiscoverView()
                    case .export:
                        ExportView()
                    }
                }
                .groupBoxStyle(LiquidGroupBoxStyle())
                .liquidPane(cornerRadius: LiquidMetrics.paneRadius)
                .padding(20)
            }
        }
        .background(WindowAppearanceConfigurator().frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .status) {
                LiquidStatusBadge(text: appState.statusMessage)
            }
        }
    }

    private func icon(for item: SidebarItem) -> String {
        switch item {
        case .library: return "music.note.list"
        case .plan: return "wand.and.stars"
        case .sets: return "list.number"
        case .gaps: return "link.badge.plus"
        case .discover: return "magnifyingglass"
        case .export: return "square.and.arrow.up"
        }
    }
}
