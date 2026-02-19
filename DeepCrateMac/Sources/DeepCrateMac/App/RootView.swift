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
                LinearGradient(
                    colors: [Color.black.opacity(0.20), Color.blue.opacity(0.12), Color.black.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                List(SidebarItem.allCases, selection: $selection) { item in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: item))
                            .font(.title3.weight(.semibold))
                            .frame(width: 24)
                        Text(item.rawValue)
                            .font(.title3.weight(.semibold))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .tag(item)
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)
                .background(Color.clear)
            }
            .navigationTitle("DeepCrate")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 280)
        } detail: {
            ZStack {
                LinearGradient(
                    colors: [Color.blue.opacity(0.10), Color.white.opacity(0.05), Color.cyan.opacity(0.09)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 520, height: 520)
                    .blur(radius: 70)
                    .offset(x: -300, y: -260)

                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 620, height: 620)
                    .blur(radius: 90)
                    .offset(x: 340, y: 260)

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
                .frame(maxWidth: 1380, maxHeight: .infinity, alignment: .topLeading)
                .liquidPane(cornerRadius: LiquidMetrics.paneRadius)
                .padding(24)
            }
        }
        .controlSize(.large)
        .toolbar {
            ToolbarItem(placement: .status) {
                LiquidStatusBadge(text: appState.statusMessage)
            }
        }
    }
}

private extension RootView {
    func icon(for item: SidebarItem) -> String {
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
