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
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var showsCompactToolbarStatus = false

    var body: some View {
        GeometryReader { proxy in
            NavigationSplitView(columnVisibility: $splitViewVisibility) {
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
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .allowsTightening(true)
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
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
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
                    .padding(detailPanePadding(for: proxy.size.width))
                }
            }
            .navigationSplitViewStyle(.balanced)
            .background(WindowAppearanceConfigurator(minContentSize: CGSize(width: 820, height: 600)))
            .onAppear {
                applyResponsiveChrome(for: proxy.size.width)
            }
            .onChange(of: proxy.size) { _, newSize in
                applyResponsiveChrome(for: newSize.width)
            }
        }
        .controlSize(.large)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Toggle Sidebar")
            }

            ToolbarItem(placement: .status) {
                if showsCompactToolbarStatus {
                    CompactToolbarStatusBadge(
                        taskLabel: appState.activeTaskLabel,
                        statusText: appState.statusMessage,
                        isWorking: appState.isWorking,
                        progressCurrent: appState.progressCurrent,
                        progressTotal: appState.progressTotal,
                        indeterminate: appState.progressIndeterminate
                    )
                } else {
                    LiquidStatusBadge(
                        text: appState.statusMessage,
                        taskLabel: appState.activeTaskLabel,
                        isWorking: appState.isWorking,
                        progressCurrent: appState.progressCurrent,
                        progressTotal: appState.progressTotal,
                        indeterminate: appState.progressIndeterminate,
                        updatedAt: appState.statusUpdatedAt
                    )
                }
            }
        }
    }
}

private extension RootView {
    func applyResponsiveChrome(for width: CGFloat) {
        let compactStatus = width < 1180
        if showsCompactToolbarStatus != compactStatus {
            showsCompactToolbarStatus = compactStatus
        }

        let desiredVisibility: NavigationSplitViewVisibility = width < 1020 ? .detailOnly : .all
        if splitViewVisibility != desiredVisibility {
            splitViewVisibility = desiredVisibility
        }
    }

    func detailPanePadding(for width: CGFloat) -> CGFloat {
        if width < 980 { return 14 }
        if width < 1180 { return 18 }
        return 24
    }

    func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }

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

private struct CompactToolbarStatusBadge: View {
    let taskLabel: String
    let statusText: String
    let isWorking: Bool
    let progressCurrent: Int
    let progressTotal: Int
    let indeterminate: Bool

    private var iconName: String {
        isWorking ? "arrow.triangle.2.circlepath" : "checkmark.seal.fill"
    }

    private var tone: Color {
        isWorking ? .blue : .green
    }

    private var progressLabel: String {
        guard isWorking else { return "Ready" }
        if indeterminate || progressTotal <= 0 { return "Working" }
        return "\(min(progressCurrent, progressTotal))/\(progressTotal)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(tone)
                .symbolEffect(.pulse.byLayer, isActive: isWorking)
            VStack(alignment: .leading, spacing: 1) {
                Text(taskLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(progressLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
        )
        .help(statusText)
    }
}
