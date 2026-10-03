import SwiftUI
import UIKit

struct EnvironmentTestView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var orientation = "unknown"

    private var schemeName: String {
        colorScheme == .dark ? "dark" : "light"
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Colour Scheme: \(schemeName)")
                .accessibilityIdentifier("environment-test-scheme")
                .accessibilityValue(schemeName)

            Text("Content Size: \(dynamicTypeSize.categoryName)")
                .accessibilityIdentifier("environment-test-content-size")
                .accessibilityValue(dynamicTypeSize.categoryName)

            Text("Interface Orientation: \(orientation)")
                .accessibilityIdentifier("environment-test-orientation")
                .accessibilityValue(orientation)

            Spacer()
        }
        .padding()
        .background(OrientationProbe { orientation = $0 })
        .navigationTitle("Environment Test")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension DynamicTypeSize {
    var categoryName: String {
        switch self {
        case .xSmall: return "extra-small"
        case .small: return "small"
        case .medium: return "medium"
        case .large: return "large"
        case .xLarge: return "extra-large"
        case .xxLarge: return "extra-extra-large"
        case .xxxLarge: return "extra-extra-extra-large"
        case .accessibility1: return "accessibility-medium"
        case .accessibility2: return "accessibility-large"
        case .accessibility3: return "accessibility-extra-large"
        case .accessibility4: return "accessibility-extra-extra-large"
        case .accessibility5: return "accessibility-extra-extra-extra-large"
        @unknown default: return "unknown"
        }
    }
}

private struct OrientationProbe: UIViewRepresentable {
    let onChange: (String) -> Void

    func makeUIView(context: Context) -> OrientationProbeView {
        let view = OrientationProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: OrientationProbeView, context: Context) {
        view.onChange = onChange
    }
}

final class OrientationProbeView: UIView {
    var onChange: ((String) -> Void)?
    private var observation: NSKeyValueObservation?
    private var lastReported: String?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observation = window?.windowScene?.observe(\.effectiveGeometry) { [weak self] _, _ in
            DispatchQueue.main.async { self?.report() }
        }
        report()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    private func report() {
        guard let scene = window?.windowScene else { return }
        let name = Self.name(for: scene.interfaceOrientation)
        guard name != lastReported else { return }
        lastReported = name
        DispatchQueue.main.async { [onChange] in onChange?(name) }
    }

    private static func name(for orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait-upside-down"
        case .landscapeLeft: return "landscape-left"
        case .landscapeRight: return "landscape-right"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}

#Preview {
    NavigationStack {
        EnvironmentTestView()
    }
}
