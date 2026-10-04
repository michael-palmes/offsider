import ArgumentParser

enum GuideTopic: String, CaseIterable, ExpressibleByArgument {
    case selectors
    case verify
    case errors
    case android
    case reactNative = "react-native"
    case turnstile
    case foldables
    case batch
    case screenshots
    case describeUI = "describe-ui"
    case deviceState = "device-state"
    case migrate

    var readItWhen: String {
        switch self {
        case .selectors: "A selector misses, matches twice, or the target is off screen, covered or moving; you need coordinates, gestures or sliders"
        case .verify: "You need proof an input worked, `--verify` exited 5, or you are waiting on a condition"
        case .errors: "A command exited non-zero, the device is busy, or doctor reports a problem"
        case .android: "The device is an Android emulator or a USB phone"
        case .reactNative: "The app is React Native or Expo, debug or release"
        case .turnstile: "You need to tick a Cloudflare Turnstile checkbox, or to know the tap does not bypass the check"
        case .foldables: "The device folds or has more than one display"
        case .batch: "A flow has three or more steps"
        case .screenshots: "You need pixels: charts, maps, web views, masked secure fields or video"
        case .describeUI: "You need more than `--summary`: JSON, filters, the byte budget or `--diff`"
        case .deviceState: "You change appearance, text size, orientation, permissions, the status bar or biometrics"
        case .migrate: "You know idb, Maestro or agent-device and want the Offsider equivalent"
        }
    }
}
