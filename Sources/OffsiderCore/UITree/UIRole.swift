import Foundation

/// Cross-platform element role; each backend maps its native types onto these.
public enum UIRole: String, CaseIterable, Sendable {
    case application
    case window
    case group
    case other
    case button
    case link
    case menuItem
    case tab
    case tabBar
    case segmentedControl
    case text
    case header
    case image
    case progress
    case textField
    case secureTextField
    case searchField
    case textArea
    case `switch`
    case checkbox
    case radioButton
    case slider
    case picker
    case cell
    case list
    case scrollView
    case keyboard

    /// Label and value selectors prefer actionable matches over plain text or containers.
    public var isActionable: Bool {
        switch self {
        case .button, .cell, .checkbox, .link, .menuItem, .radioButton, .secureTextField,
             .segmentedControl, .slider, .switch, .tab, .textArea, .textField:
            return true
        case .application, .window, .group, .other, .tabBar, .text, .header, .image, .progress,
             .searchField, .picker, .list, .scrollView, .keyboard:
            return false
        }
    }
}
