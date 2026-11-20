import Foundation
@testable import OffsiderCore
import Testing

/// Trees shaped like the prompts an Android 16 emulator and an iOS 27 simulator showed for the playground.
enum AlertFixtures {
    static let android = "com.mpalmes.offsider.playground.rn"
    static let ios = "com.mpalmes.offsider.playground"
    static let controller = "com.google.android.permissioncontroller"

    static func androidNode(_ role: UIRole, entry: String? = nil, label: String? = nil, frame: UIFrame, package: String = controller, children: [UINode] = []) -> UINode {
        let id = entry.map { "com.android.permissioncontroller:id/\($0)" }
        return UINode(role: role, id: id, label: label, frame: frame, native: .android(AndroidNativeAttributes(resourceId: id, package: package)), children: children)
    }

    /// The camera dialog, with `labels` for its message and three buttons.
    static func androidDialog(
        labels: [String] = ["Allow Playground to take pictures and record video?", "While using the app", "Only this time", "Don’t allow"],
        entries: [String] = ["permission_allow_foreground_only_button", "permission_allow_one_time_button", "permission_deny_button"],
        package: String = controller
    ) -> UITree {
        let buttons = entries.enumerated().map { index, entry in
            androidNode(.button, entry: entry, label: labels[index + 1], frame: UIFrame(x: 125, y: 400 + Double(index) * 60, width: 600, height: 56), package: package)
        }
        let message = androidNode(.text, entry: "permission_message", label: labels[0], frame: UIFrame(x: 125, y: 350, width: 600, height: 27), package: package)
        let root = androidNode(.application, label: labels[0], frame: UIFrame(x: 85, y: 266, width: 681, height: 354), package: package, children: [message] + buttons)
        return UITree(platform: .android, device: "emulator-5554", roots: [root])
    }

    static func iosNode(_ role: UIRole, type: String? = nil, id: String? = nil, label: String? = nil, frame: UIFrame, children: [UINode] = []) -> UINode {
        UINode(role: role, id: id, label: label, frame: frame, native: .ios(IOSNativeAttributes(type: type, pid: 501)), children: children)
    }

    /// SpringBoard's tree with one app card beneath an alert; `service` gives the alert and its buttons their privacy ids.
    static func iosAlert(
        title: String = "Allow “Playground” to access your camera?",
        buttons: [String] = ["Don’t Allow", "Allow"],
        service: String? = "kTCCServiceCamera",
        buttonIDs: [String?]? = nil,
        card: (bundle: String, name: String)? = (ios, "Playground")
    ) -> UITree {
        let screen = UIFrame(x: 0, y: 0, width: 402, height: 874)
        let ids = buttonIDs ?? (service.map { name in buttons.enumerated().map { index, _ in index == 0 ? "\(name)-deny-button" : "\(name)-allow-button" } } ?? buttons.map { _ in nil })
        let nodes = buttons.enumerated().map { index, label -> UINode in
            let frame = UIFrame(x: 57 + Double(index) * 148, y: 529, width: 140, height: 48)
            let inner = iosNode(.button, type: "Button", id: ids[index], label: label, frame: frame)
            return iosNode(.button, type: "Button", id: ids[index], label: label, frame: frame, children: [inner])
        }
        let text = [
            iosNode(.text, type: "StaticText", label: title, frame: UIFrame(x: 71, y: 420, width: 260, height: 42)),
            iosNode(.text, type: "StaticText", label: "Raises the prompt for a test.", frame: UIFrame(x: 71, y: 470, width: 260, height: 38)),
        ]
        let alert = iosNode(.other, type: "Sheet", id: service.map { "\($0)-alert" }, label: title, frame: UIFrame(x: 41, y: 309, width: 320, height: 283), children: text + nodes)
        var children: [UINode] = []
        if let card {
            children.append(iosNode(.group, type: "Group", id: "card:\(card.bundle):sceneID:\(card.bundle)-0000", label: card.name, frame: screen))
        }
        let root = iosNode(.application, type: "Application", label: " ", frame: screen, children: children + [alert])
        return UITree(platform: .ios, device: "00000000-0000-0000-0000-000000000001", roots: [root])
    }
}

@Suite("Android's permission dialog, read by button ids")
struct AndroidPermissionPromptTests {
    @Test("accept is While using the app and deny is Don't allow, by their ids; a one-time grant is never accept")
    func rolesByID() throws {
        let prompt = try #require(AndroidPermissionPrompt.read(AlertFixtures.androidDialog(), app: AlertFixtures.android, token: "1a2b"))
        #expect(prompt.title == "Allow Playground to take pictures and record video?")
        #expect(prompt.buttons.map(\.role) == [.accept, .other, .deny])
        #expect(try prompt.button(for: .accept).label == "While using the app")
        #expect(try prompt.button(for: .deny).label == "Don’t allow")
        #expect(prompt.source == AlertFixtures.controller && prompt.token == "1a2b")
    }

    @Test("another language, even one whose words read the other way round in English, changes nothing")
    func otherLanguage() throws {
        let german = AlertFixtures.androidDialog(labels: ["Playground erlauben, Bilder und Videos aufzunehmen?", "Bei Nutzung der App", "Nur dieses Mal", "Nicht zulassen"])
        let prompt = try #require(AndroidPermissionPrompt.read(german, app: AlertFixtures.android, token: ""))
        #expect(try prompt.button(for: .accept).label == "Bei Nutzung der App")
        #expect(try prompt.button(for: .deny).label == "Nicht zulassen")

        let swapped = AlertFixtures.androidDialog(labels: ["?", "Don’t allow", "Only this time", "Allow"])
        let odd = try #require(AndroidPermissionPrompt.read(swapped, app: AlertFixtures.android, token: ""))
        #expect(try odd.button(for: .accept).label == "Don’t allow")
        #expect(try odd.button(for: .deny).label == "Allow")
    }

    @Test("a plain Allow is accept when no narrower lasting grant is offered, and All the time never is")
    func narrowestLastingGrant() throws {
        let notifications = AlertFixtures.androidDialog(labels: ["Allow Playground to send you notifications?", "Allow", "Don’t allow"], entries: ["permission_allow_button", "permission_deny_button"])
        #expect(try #require(AndroidPermissionPrompt.read(notifications, app: AlertFixtures.android, token: "")).button(for: .accept).label == "Allow")

        let always = AlertFixtures.androidDialog(
            labels: ["Allow all the time?", "Allow all the time", "Keep while using the app"],
            entries: ["permission_allow_always_button", "permission_no_upgrade_button"]
        )
        let prompt = try #require(AndroidPermissionPrompt.read(always, app: AlertFixtures.android, token: ""))
        #expect(prompt.buttons.map(\.role) == [.other, .deny])
        #expect(throws: AppPrompt.ChoiceFailure.noButton(.accept)) { try prompt.button(for: .accept) }
    }

    @Test("a window of another package, or a dialog whose buttons carry no permission id, is not read")
    func notADialog() {
        #expect(AndroidPermissionPrompt.read(AlertFixtures.androidDialog(package: "com.example.other"), app: AlertFixtures.android, token: "") == nil)
        let unknown = AlertFixtures.androidDialog(entries: ["button1", "button2", "button3"])
        #expect(AndroidPermissionPrompt.read(unknown, app: AlertFixtures.android, token: "") == nil)
        #expect(AndroidPermissionPrompt.isDialog(unknown))
    }
}

@Suite("An iOS simulator's permission alert")
struct IOSPermissionAlertTests {
    @Test("a privacy alert over the app's card is read by its button ids")
    func privacyAlert() throws {
        let prompt = try IOSPermissionAlert.read(AlertFixtures.iosAlert(), app: AlertFixtures.ios)
        #expect(prompt.title == "Allow “Playground” to access your camera?")
        #expect(prompt.message == "Raises the prompt for a test.")
        #expect(prompt.buttons.map(\.label) == ["Don’t Allow", "Allow"])
        #expect(prompt.buttons.map(\.role) == [.deny, .accept])
    }

    @Test("ids decide in any language, and a privacy alert's Continue is never accept")
    func idsBeatWords() throws {
        let french = AlertFixtures.iosAlert(title: "Autoriser « Playground » à accéder à l’appareil photo ?", buttons: ["Refuser", "Autoriser"])
        #expect(try IOSPermissionAlert.read(french, app: AlertFixtures.ios).buttons.map(\.role) == [.deny, .accept])

        let staged = AlertFixtures.iosAlert(
            title: "Allow “Playground” to access your contacts?", buttons: ["Don’t Allow", "Continue"], service: "kTCCServiceAddressBook",
            buttonIDs: ["kTCCServiceAddressBook-deny-button", "kTCCServiceAddressBook-learn-more-button"]
        )
        let prompt = try IOSPermissionAlert.read(staged, app: AlertFixtures.ios)
        #expect(prompt.buttons.map(\.role) == [.deny, .other])
        #expect(throws: AppPrompt.ChoiceFailure.noButton(.accept)) { try prompt.button(for: .accept) }
    }

    @Test("an alert with no ids is read by its English labels, and accept is the grant that lasts while the app is used")
    func labelsWithoutIDs() throws {
        let notifications = AlertFixtures.iosAlert(title: "“Playground” Would Like to Send You Notifications", service: nil)
        #expect(try IOSPermissionAlert.read(notifications, app: AlertFixtures.ios).buttons.map(\.role) == [.deny, .accept])

        let location = AlertFixtures.iosAlert(title: "Allow “Playground” to use your location?", buttons: ["Allow Once", "Allow While Using App", "Don’t Allow"], service: nil)
        let prompt = try IOSPermissionAlert.read(location, app: AlertFixtures.ios)
        #expect(try prompt.button(for: .accept).label == "Allow While Using App")
        #expect(try prompt.button(for: .deny).label == "Don’t Allow")

        let german = AlertFixtures.iosAlert(title: "„Playground“ möchte dir Mitteilungen senden", buttons: ["Nicht erlauben", "Erlauben"], service: nil)
        let unread = try IOSPermissionAlert.read(german, app: AlertFixtures.ios)
        #expect(unread.buttons.map(\.role) == [.other, .other])
        #expect(try unread.button(for: .label("Erlauben")).label == "Erlauben")
    }

    @Test("each English button means one thing: the grant that lasts while the app is used, a refusal, or an answer only choose picks", arguments: [
        ("Allow While Using App", "accept"), ("Allow", "accept"), ("OK", "accept"),
        ("Don’t Allow", "deny"), ("Ask App Not to Track", "deny"),
        ("Allow Once", "other"), ("Always Allow", "other"), ("Change to Always Allow", "other"), ("Keep Only While Using", "other"),
        ("Allow Full Access", "other"), ("Allow Access to All Photos", "other"), ("Limit Access…", "other"), ("Select Photos…", "other"), ("Continue", "other"),
    ])
    func labelTable(label: String, role: String) throws {
        // Beside a button no table row knows, so the row under test alone decides its role.
        let tree = AlertFixtures.iosAlert(title: "Allow “Playground” to use your location?", buttons: [label, "Zzz"], service: nil)
        let prompt = try IOSPermissionAlert.read(tree, app: AlertFixtures.ios)
        #expect(prompt.buttons.map(\.role.rawValue) == [role, "other"])
    }

    @Test("the table has no row the test above does not name, and a narrower lasting grant wins over a plain Allow")
    func labelTableIsWhole() throws {
        #expect(IOSPermissionAlert.labelRoles.count == 14)
        let both = AlertFixtures.iosAlert(title: "Allow “Playground” to use your location?", buttons: ["Allow", "Allow While Using App", "Always Allow", "Allow Once", "Don’t Allow"], service: nil)
        let prompt = try IOSPermissionAlert.read(both, app: AlertFixtures.ios)
        #expect(prompt.buttons.map(\.role) == [.other, .accept, .other, .other, .deny])
    }

    @Test("accept and deny act only on a title shaped like a permission request; any other alert that names the app is for show and choose", arguments: [
        ("“Playground” Would Like to Send You Notifications", true),
        ("“Playground” would like to find and connect to devices on your local network", true),
        ("Allow “Playground” to use your location?", true),
        ("“Playground” Needs to Be Updated", false),
        ("Turn on Location Services to allow “Playground” to determine your location", false),
        ("Open in “Playground”?", false),
    ])
    func permissionShape(title: String, asks: Bool) throws {
        let prompt = try IOSPermissionAlert.read(AlertFixtures.iosAlert(title: title, buttons: ["Don’t Allow", "Allow"], service: nil), app: AlertFixtures.ios)
        #expect(prompt.buttons.map(\.role) == (asks ? [.deny, .accept] : [.other, .other]))
        #expect(try prompt.button(for: .label("Allow")).label == "Allow")
    }

    @Test("a privacy prompt's ids never make a broader or one-time grant the default, and decide alone only between two buttons")
    func idsNeverWiden() throws {
        let photos = AlertFixtures.iosAlert(
            title: "Allow “Playground” to access your photos?", buttons: ["Limit Access…", "Allow Full Access", "Don’t Allow"], service: "kTCCServicePhotos",
            buttonIDs: ["kTCCServicePhotos-limited-button", "kTCCServicePhotos-allow-button", "kTCCServicePhotos-deny-button"]
        )
        #expect(try IOSPermissionAlert.read(photos, app: AlertFixtures.ios).buttons.map(\.role) == [.other, .other, .deny])

        let broad = AlertFixtures.iosAlert(title: "Allow “Playground” to use your location?", buttons: ["Don’t Allow", "Always Allow"], service: "kTCCServiceLocation")
        #expect(try IOSPermissionAlert.read(broad, app: AlertFixtures.ios).buttons.map(\.role) == [.deny, .other])

        let threeUnknown = AlertFixtures.iosAlert(
            title: "Autoriser « Playground » ?", buttons: ["Refuser", "Autoriser", "Toujours"], service: "kTCCServiceCamera",
            buttonIDs: ["kTCCServiceCamera-deny-button", "kTCCServiceCamera-allow-button", nil]
        )
        #expect(try IOSPermissionAlert.read(threeUnknown, app: AlertFixtures.ios).buttons.map(\.role) == [.deny, .other, .other])
    }

    @Test("an alert over another app, or with no app beneath it, is another app's")
    func anotherAppBeneath() {
        let other = AlertFixtures.iosAlert(card: ("com.example.other", "Playground"))
        #expect(throws: AppPromptRefusal.otherApp(requester: "com.example.other", why: #"the alert "Allow “Playground” to access your camera?" is over com.example.other"#)) {
            try IOSPermissionAlert.read(other, app: AlertFixtures.ios)
        }
        let none = AlertFixtures.iosAlert(card: nil)
        #expect { try IOSPermissionAlert.read(none, app: AlertFixtures.ios) } throws: { error in
            guard case .otherApp(nil, _) = error as? AppPromptRefusal else { return false }
            return true
        }
    }

    @Test("an alert that names another app first, names none, or asks nothing is refused", arguments: [
        ("“Browser” wants to open “Playground”", ["Cancel", "Open"], "otherApp"),
        ("Software Update", ["Later", "Install Now"], "notPermission"),
        ("“Playground” Is No Longer Available", ["OK"], "notPermission"),
    ])
    func notThisAppsPrompt(title: String, buttons: [String], expected: String) {
        let tree = AlertFixtures.iosAlert(title: title, buttons: buttons, service: nil)
        #expect { try IOSPermissionAlert.read(tree, app: AlertFixtures.ios) } throws: { error in
            switch error as? AppPromptRefusal {
            case .otherApp: return expected == "otherApp"
            case .notPermission: return expected == "notPermission"
            default: return false
            }
        }
    }

    @Test("an alert this iOS lists in a shape Offsider does not know stops the command; it is never reported as no prompt")
    func unknownAlertShape() {
        var tree = AlertFixtures.iosAlert()
        func untyped(_ node: UINode) -> UINode {
            var copy = node
            if case .ios(var native) = copy.native, native.type == "Sheet" {
                native.type = "Other"
                copy.native = .ios(native)
            }
            copy.children = copy.children.map(untyped)
            return copy
        }
        tree.roots = tree.roots.map(untyped)
        #expect { try IOSPermissionAlert.read(tree, app: AlertFixtures.ios) } throws: { error in
            guard case .notPermission = error as? AppPromptRefusal else { return false }
            return true
        }
    }

    @Test("the app's own screen, with no alert, is not shown; a dock of buttons is no alert")
    func noAlert() {
        let screen = UIFrame(x: 0, y: 0, width: 402, height: 874)
        let dock = AlertFixtures.iosNode(.group, type: "Group", label: "Dock", frame: UIFrame(x: 0, y: 780, width: 402, height: 94), children: [
            AlertFixtures.iosNode(.button, type: "Button", label: "Phone", frame: UIFrame(x: 20, y: 790, width: 60, height: 60)),
        ])
        let card = AlertFixtures.iosNode(.group, id: "card:\(AlertFixtures.ios):sceneID:\(AlertFixtures.ios)-0000", label: "Playground", frame: screen)
        let tree = UITree(platform: .ios, device: "sim", roots: [AlertFixtures.iosNode(.application, label: " ", frame: screen, children: [card, dock])])
        #expect(throws: AppPromptRefusal.notShown(front: AlertFixtures.ios)) { try IOSPermissionAlert.read(tree, app: AlertFixtures.ios) }
    }
}

@Suite("A prompt's buttons, report and capture")
struct AppPromptTests {
    static let prompt = AppPrompt(app: "com.example.app", title: "Allow Example to take pictures?", buttons: [
        AppPrompt.Button(label: "While using the app", role: .accept, frame: UIFrame(x: 100, y: 400, width: 200, height: 50)),
        AppPrompt.Button(label: "Don’t allow", role: .deny, frame: UIFrame(x: 100, y: 460, width: 200, height: 50)),
    ], frame: UIFrame(x: 80, y: 300, width: 240, height: 240), source: "com.example.controller")

    @Test("choose matches one button's whole text, quote style aside; part of it, or a text no button has, is unknown")
    func chooseByLabel() throws {
        #expect(try Self.prompt.button(for: .label("Don't allow")).role == .deny)
        #expect(throws: AppPrompt.ChoiceFailure.unknownLabel("allow")) { try Self.prompt.button(for: .label("allow")) }
        #expect(throws: AppPrompt.ChoiceFailure.unknownLabel("Nope")) { try Self.prompt.button(for: .label("Nope")) }
        var twins = Self.prompt
        twins.buttons.append(AppPrompt.Button(label: "Don’t allow", role: .other, frame: UIFrame(x: 100, y: 520, width: 200, height: 50)))
        #expect(throws: AppPrompt.ChoiceFailure.ambiguousLabel("Don’t allow")) { try twins.button(for: .label("Don’t allow")) }
    }

    @Test("everything outside the prompt's box is four regions that meet its edges and cover the rest of the screen")
    func outsideRegions() {
        let regions = Self.prompt.outside(on: UIFrame(x: 0, y: 0, width: 400, height: 800))
        #expect(regions == [
            PointRegion(x: 0, y: 0, width: 400, height: 300),
            PointRegion(x: 0, y: 540, width: 400, height: 260),
            PointRegion(x: 0, y: 300, width: 80, height: 240),
            PointRegion(x: 320, y: 300, width: 80, height: 240),
        ])
        var wide = Self.prompt
        wide.frame = UIFrame(x: 0, y: 300, width: 400, height: 500)
        #expect(wide.outside(on: UIFrame(x: 0, y: 0, width: 400, height: 800)) == [PointRegion(x: 0, y: 0, width: 400, height: 300)])
    }

    @Test("show prints the text and each button with its role, and --json the same, naming the device's words as untrusted")
    func showReport() throws {
        let report = AlertReport(prompt: Self.prompt)
        #expect(report.textLines == [
            #"Prompt for com.example.app: "Allow Example to take pictures?""#,
            #"  button "While using the app" (accept)"#,
            #"  button "Don’t allow" (deny)"#,
        ])
        let json = try #require(JSONSerialization.jsonObject(with: Data(report.jsonLine(device: DeviceID(rawValue: "emulator-5554", platform: .android)).utf8)) as? [String: Any])
        #expect(json["action"] as? String == "show")
        #expect(json["button"] is NSNull && json["next"] is NSNull)
        let prompt = try #require(json["prompt"] as? [String: Any])
        #expect(prompt["title"] as? String == "Allow Example to take pictures?")
        #expect((prompt["buttons"] as? [[String: Any]])?.map { $0["role"] as? String } == ["accept", "deny"])
        #expect(json["untrusted"] as? [String] == ["prompt.title", "prompt.message", "prompt.buttons[].label"])
    }

    @Test("an answer's line in a run's manifest and timeline carries the prompt's title and the button; other lines are unchanged")
    func timeline() throws {
        let time = Date(timeIntervalSince1970: 1_790_000_000)
        var line = RunManifestLine(command: "alert", device: "emulator-5554", platform: "android", time: time, ms: 800, exit: 0)
        let plain = line.jsonLine(timeZone: TimeZone(identifier: "UTC")!)
        #expect(!plain.contains("prompt") && !plain.contains("button"))
        line.prompt = "Allow Example to take pictures?"
        line.button = "While using the app"
        let written = line.jsonLine(timeZone: TimeZone(identifier: "UTC")!)
        #expect(written.hasSuffix(#""prompt":"Allow Example to take pictures?","button":"While using the app"}"#))
        #expect(try RunManifestLine(jsonLine: written) == line)
        let timeline = RunTimeline(dir: "/tmp/run", state: RunState(label: nil, startedAt: time), entries: [line], unrecorded: [])
        #expect(timeline.line(for: line, timeZone: TimeZone(identifier: "UTC")!).hasSuffix(#"alert emulator-5554 ok ("While using the app" on "Allow Example to take pictures?")"#))
    }
}
