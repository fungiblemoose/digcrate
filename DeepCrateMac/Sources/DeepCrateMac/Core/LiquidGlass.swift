import AppKit
import SwiftUI

enum LiquidMetrics {
    static let paneRadius: CGFloat = 30
    static let cardRadius: CGFloat = 22
    static let compactRadius: CGFloat = 16
}

struct LiquidGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.headline.weight(.semibold))
            configuration.content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LiquidMetrics.cardRadius, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiquidMetrics.cardRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.45), Color.white.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 6)
    }
}

struct LiquidStatusBadge: View {
    let text: String
    var symbol: String = "dot.radiowaves.left.and.right"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
            Text(text)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.primary.opacity(0.82))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.5), Color.white.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

struct VisualEffectGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

struct WindowAppearanceConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureWindowIfAvailable(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindowIfAvailable(from: nsView)
        }
    }

    private func configureWindowIfAvailable(from view: NSView) {
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
    }
}

extension View {
    func liquidPane(cornerRadius: CGFloat = LiquidMetrics.paneRadius) -> some View {
        self
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.10), radius: 24, x: 0, y: 12)
    }

    func liquidCard(
        cornerRadius: CGFloat = LiquidMetrics.cardRadius,
        material: Material = .ultraThinMaterial,
        contentPadding: CGFloat = 18,
        shadowOpacity: Double = 0.06
    ) -> some View {
        self
            .padding(contentPadding)
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.45), Color.white.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(shadowOpacity), radius: 12, x: 0, y: 7)
    }
}
