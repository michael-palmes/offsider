import Foundation

/// Names a device for people, where a serial alone says little: `Motorola moto g (ZY22FAKE01)`.
public enum DeviceName {
    /// The maker first, capitalised, unless the model already starts with it; nil when both are unknown.
    public static func label(maker: String?, model: String?) -> String? {
        let maker = (maker ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        guard !maker.isEmpty else { return model }
        let brand = maker.prefix(1).uppercased() + maker.dropFirst()
        guard let model else { return brand }
        return model.lowercased().hasPrefix(maker.lowercased()) ? model : "\(brand) \(model)"
    }

    /// `label (id)`, or the id alone when the label is missing or repeats it.
    public static func display(_ id: String, label: String?) -> String {
        guard let label, !label.isEmpty, label != id else { return id }
        return "\(label) (\(id))"
    }

    /// A phone by maker and the model adb lists, an emulator by its AVD name; `listed` is that model or AVD name.
    public static func android(serial: String, listed: String?, maker: String?) -> String {
        let listed = listed == serial ? nil : listed
        if case .androidSerial = DeviceIDClassifier.classify(serial) { return display(serial, label: listed) }
        return display(serial, label: label(maker: maker, model: listed))
    }
}
