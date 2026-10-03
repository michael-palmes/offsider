import SwiftUI
import UIKit

struct ParkedSheetTestView: View {
    var body: some View {
        ParkedSheetRepresentable()
            .ignoresSafeArea()
            .navigationTitle("Parked Sheet")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ParkedSheetRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ParkedSheetViewController {
        ParkedSheetViewController()
    }

    func updateUIViewController(_ controller: ParkedSheetViewController, context: Context) {}
}

final class ParkedSheetViewController: UIViewController {
    private enum Position: String {
        case parked = "Parked"
        case moving = "Moving"
        case open = "Open"
    }

    static let parkedY: CGFloat = 10000
    private let sheetHeight: CGFloat = 300

    private let stateLabel = UILabel()
    private let positionLabel = UILabel()
    private let sheet = UIView()
    private var position: Position = .parked

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        configureLabel(stateLabel, identifier: "parked-sheet-test-state")
        configureLabel(positionLabel, identifier: "parked-sheet-test-position")
        setState("Initial")
        setPosition(.parked)

        let body = UIStackView(arrangedSubviews: [
            stateLabel,
            positionLabel,
            makeButton("Open Filters", identifier: "parked-sheet-test-open") { [weak self] in
                self?.openSheet(duration: 0.6)
            },
            makeButton("Open Filters Slowly", identifier: "parked-sheet-test-open-slow") { [weak self] in
                self?.openSheet(duration: 2.5)
            },
            makeButton("Save", identifier: "parked-sheet-test-body-save") { [weak self] in
                self?.setState("Body save")
            },
        ])
        body.axis = .vertical
        body.spacing = 16
        body.alignment = .center
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            body.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])

        let title = UILabel()
        title.text = "Filters"
        title.font = .preferredFont(forTextStyle: .title2)
        title.accessibilityIdentifier = "parked-sheet-test-sheet-title"
        title.accessibilityTraits = .header

        let sheetStack = UIStackView(arrangedSubviews: [
            title,
            makeButton("Apply Filters", identifier: "parked-sheet-test-apply") { [weak self] in
                self?.setState("Filters applied")
            },
            makeButton("Save", identifier: "parked-sheet-test-sheet-save") { [weak self] in
                self?.setState("Sheet save")
            },
            makeButton("Close Filters", identifier: "parked-sheet-test-close") { [weak self] in
                self?.closeSheet()
            },
        ])
        sheetStack.axis = .vertical
        sheetStack.spacing = 16
        sheetStack.alignment = .center
        sheetStack.translatesAutoresizingMaskIntoConstraints = false

        sheet.backgroundColor = .secondarySystemBackground
        sheet.layer.cornerRadius = 16
        sheet.layer.shadowOpacity = 0.2
        sheet.layer.shadowRadius = 8
        sheet.addSubview(sheetStack)
        NSLayoutConstraint.activate([
            sheetStack.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 24),
            sheetStack.centerXAnchor.constraint(equalTo: sheet.centerXAnchor),
        ])
        view.addSubview(sheet)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard position != .moving else { return }
        sheet.frame = sheetFrame(at: position == .open ? openY : Self.parkedY)
    }

    private var openY: CGFloat { view.bounds.height - sheetHeight }

    private func sheetFrame(at y: CGFloat) -> CGRect {
        CGRect(x: 0, y: y, width: view.bounds.width, height: sheetHeight)
    }

    private func openSheet(duration: TimeInterval) {
        guard position == .parked else { return }
        sheet.frame = sheetFrame(at: view.bounds.height)
        setPosition(.moving)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            self.sheet.frame = self.sheetFrame(at: self.openY)
        } completion: { _ in
            self.setPosition(.open)
        }
    }

    private func closeSheet() {
        guard position == .open else { return }
        setPosition(.moving)
        UIView.animate(withDuration: 0.6, delay: 0, options: [.curveEaseIn]) {
            self.sheet.frame = self.sheetFrame(at: self.view.bounds.height)
        } completion: { _ in
            self.sheet.frame = self.sheetFrame(at: Self.parkedY)
            self.setPosition(.parked)
        }
    }

    private func setState(_ value: String) {
        stateLabel.text = "Parked Sheet State: \(value)"
        stateLabel.accessibilityValue = value
    }

    private func setPosition(_ value: Position) {
        position = value
        positionLabel.text = "Sheet Position: \(value.rawValue)"
        positionLabel.accessibilityValue = value.rawValue
    }

    private func configureLabel(_ label: UILabel, identifier: String) {
        label.font = .preferredFont(forTextStyle: .headline)
        label.accessibilityIdentifier = identifier
    }

    private func makeButton(_ title: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = title
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = identifier
        return button
    }
}

#Preview {
    NavigationStack {
        ParkedSheetTestView()
    }
}
