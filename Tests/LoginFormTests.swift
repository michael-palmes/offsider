import Foundation
import OffsiderCore
import Testing

@Suite("Login form")
struct LoginFormTests {
    @Test("a covered welcome button is not the submit control, and the Turnstile shell is kept")
    func detectsTheFrontmostForm() throws {
        let found = try LoginForm.detect(in: SignInFixture.tree())
        #expect(found.identity.id == "email-field")
        #expect(found.password.id == "password-field")
        #expect(found.submit.id == "login-button")
        #expect(found.submit.enabled == false)
        #expect(found.turnstileShell == UIFrame(x: 16, y: 375, width: 370, height: 80))
    }

    @Test("e-mail and user name are identity fields, and Login feedback is not denied as back")
    func namesMatchTokens() throws {
        let email = try LoginForm.detect(in: SignInFixture.tree(submitLabel: "Login feedback", identityLabel: "E-mail"))
        #expect(email.identity.id == "email-field")
        #expect(email.submit.label == "Login feedback")
        let username = try LoginForm.detect(in: SignInFixture.tree(identityLabel: "User name"))
        #expect(username.identity.id == "email-field")
    }

    @Test("two identity fields, two submit buttons, or a covered password field each refuse")
    func ambiguousOrCoveredRefuses() {
        #expect(throws: LoginFormError.self) { try LoginForm.detect(in: SignInFixture.tree(extraIdentity: true)) }
        #expect(throws: LoginFormError.self) { try LoginForm.detect(in: SignInFixture.tree(extraSubmit: true)) }
        #expect(throws: LoginFormError.self) { try LoginForm.detect(in: SignInFixture.tree(coverPassword: true)) }
    }

    @Test("a Continue with Google button is not the submit control, and words must be whole")
    func socialSignInIsNotSubmit() throws {
        func tree(_ buttons: [UINode]) -> UITree {
            FakeUI.tree([
                FakeUI.node(.textField, id: "email-field", label: "Email", frame: FakeUI.frame(17, 212, 367, 45)),
                FakeUI.node(.secureTextField, id: "password-field", label: "Password", frame: FakeUI.frame(17, 316, 367, 45)),
            ] + buttons)
        }
        let primary = FakeUI.node(.button, label: "Log in", frame: FakeUI.frame(16, 600, 370, 44))
        let google = FakeUI.node(.button, label: "Continue with Google", frame: FakeUI.frame(16, 660, 370, 44))
        let apple = FakeUI.node(.button, id: "signInWithAppleButton", frame: FakeUI.frame(16, 720, 370, 44))
        #expect(try LoginForm.detect(in: tree([primary, google, apple])).submit.label == "Log in")

        let camel = FakeUI.node(.button, id: "signInButton", frame: FakeUI.frame(16, 600, 370, 44))
        let blog = FakeUI.node(.button, label: "Blog index", frame: FakeUI.frame(16, 660, 370, 44))
        #expect(try LoginForm.detect(in: tree([camel, blog])).submit.id == "signInButton")
    }

    @Test("a Next key on the keyboard is not the submit button")
    func keyboardNextIsNotSubmit() throws {
        let found = try LoginForm.detect(in: SignInFixture.tree(keyboardNext: true))
        #expect(found.submit.id == "login-button")
        let error = #expect(throws: LoginFormError.self) { try LoginForm.detect(in: SignInFixture.tree(keyboardNext: true, omitSubmit: true)) }
        #expect(error?.message.contains("Nothing was typed.") == true)
    }

    @Test("the input assistant and an empty container do not hide the form")
    func assistantDoesNotHideTheForm() throws {
        let found = try LoginForm.detect(in: SignInFixture.tree(assistantChrome: true, emptyCover: true))
        #expect(found.identity.id == "email-field")
        #expect(found.password.id == "password-field")
        #expect(found.submit.id == "login-button")
        #expect(throws: LoginFormError.self) {
            try LoginForm.detect(in: SignInFixture.tree(coverPassword: true, assistantChrome: true, emptyCover: true))
        }
    }

    @Test("a pinned id that is covered is a refusal, not a tap on what is in front")
    func pinnedCoverRefuses() {
        let profile = LoginProfile(bundleID: "com.example.app", password: LoginField(id: "password-field"))
        let error = #expect(throws: LoginFormError.self) { try LoginForm.detect(in: SignInFixture.tree(coverPassword: true), profile: profile) }
        #expect(error?.message.contains("covered") == true)
        #expect(error?.message.contains("Nothing was typed.") == true)
    }
}

@Suite("Keyboard dismiss")
struct KeyboardDismissTests {
    @Test("no keyboard means there is nothing to dismiss")
    func noKeyboard() {
        #expect(KeyboardDismiss.point(in: SignInFixture.tree()) == nil)
    }

    @Test("a hide keyboard control is preferred, and a short scroll view is not a safe tap")
    func hideOrSafePoint() {
        let hide = FakeUI.node(.button, label: "Hide keyboard", frame: FakeUI.frame(300, 800, 80, 30))
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 700, 402, 174), children: [hide])
        let tree = FakeUI.tree([keyboard])
        #expect(KeyboardDismiss.point(in: tree) == hide.frame?.center)

        let header = FakeUI.node(.text, label: "Welcome", frame: FakeUI.frame(0, 0, 402, 616))
        let shell = FakeUI.node(.scrollView, frame: FakeUI.frame(16, 620, 370, 80))
        let lower = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 700, 402, 174))
        let above = FakeUI.tree([header, shell, lower])
        let point = KeyboardDismiss.point(in: above)
        #expect(point != nil)
        #expect(header.frame?.contains(point!) == true)
        #expect(shell.frame?.contains(point!) == false)
    }

    @Test("the dismiss tap prefers empty space over text, and never lands on or inside a control")
    func dismissAvoidsControls() throws {
        let link = FakeUI.node(.link, label: "Forgot password?", frame: FakeUI.frame(16, 640, 370, 40))
        let pressable = FakeUI.node(.button, label: "Terms", frame: FakeUI.frame(0, 560, 402, 60), children: [
            FakeUI.node(.text, label: "Read the terms", frame: FakeUI.frame(16, 570, 370, 40)),
        ])
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 700, 402, 174))
        let caption = FakeUI.node(.text, label: "Welcome back", frame: FakeUI.frame(0, 400, 402, 120))
        let spaced = try #require(KeyboardDismiss.point(in: FakeUI.tree([caption, pressable, link, keyboard])))
        #expect([link, pressable, caption].allSatisfy { $0.frame?.contains(spaced) == false })

        let fullCaption = FakeUI.node(.text, label: "Welcome back", frame: FakeUI.frame(0, 0, 402, 560))
        let packed = try #require(KeyboardDismiss.point(in: FakeUI.tree([fullCaption, pressable, link, keyboard])))
        #expect(fullCaption.frame?.contains(packed) == true)
        #expect([link, pressable].allSatisfy { $0.frame?.contains(packed) == false })
    }

    @Test("the input assistant is not a safe place to dismiss the keyboard")
    func assistantIsNotADismissPoint() {
        let header = FakeUI.node(.text, label: "Welcome", frame: FakeUI.frame(0, 0, 402, 616))
        let bogus = FakeUI.node(.group, frame: FakeUI.frame(0, 274, 402, 1220))
        let assistant = FakeUI.node(.group, id: "SystemInputAssistantView", frame: FakeUI.frame(0, 874, 402, 44), children: [bogus])
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 700, 402, 174))
        let cover = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), children: [assistant, keyboard])
        let tree = FakeUI.tree([header, cover])
        let point = KeyboardDismiss.point(in: tree)
        #expect(header.frame?.contains(point!) == true)
    }

    @Test("a keyboard frame covers the point inside it")
    func covers() {
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 400, 402, 474))
        let tree = FakeUI.tree([keyboard])
        #expect(KeyboardDismiss.covers(UIPoint(x: 200, y: 500), in: tree))
        #expect(!KeyboardDismiss.covers(UIPoint(x: 200, y: 100), in: tree))
    }

    @Test("a screen-wide keyboard window covers only its keys")
    func backdropCoversTheKeysOnly() {
        let key = FakeUI.node(.button, label: "q", frame: FakeUI.frame(10, 700, 40, 40))
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 0, 402, 874), children: [key])
        let header = FakeUI.node(.text, label: "Welcome", frame: FakeUI.frame(0, 0, 402, 600))
        let tree = FakeUI.tree([header, keyboard])
        #expect(!KeyboardDismiss.covers(UIPoint(x: 200, y: 200), in: tree))
        #expect(KeyboardDismiss.covers(UIPoint(x: 30, y: 720), in: tree))
        let point = KeyboardDismiss.point(in: tree)
        #expect(point != nil)
        #expect((point?.y ?? 900) < key.frame!.y)
        #expect(KeyboardDismiss.covers(point!, in: tree) == false)
    }
}

@Suite("Login profile and foreground app")
struct LoginProfileTests {
    @Test("a profile names an app and rejects an unknown key or no app at all")
    func parses() throws {
        let parsed = try LoginProfile.parse(Data("""
        {"bundleId":"com.example.app","identity":{"id":"email-field"},"password":{"id":"password-field"},"turnstile":"required","submit":{"id":"login-button"}}
        """.utf8))
        #expect(parsed.isFor("com.example.app"))
        #expect(!parsed.isFor("com.example.android"))
        #expect(parsed.turnstile == .required)
        #expect(parsed.identity == LoginField(id: "email-field"))
        #expect(throws: LoginProfileError.self) { try LoginProfile.parse(Data("{\"bundleId\":\"com.example.app\",\"extra\":true}".utf8)) }
        #expect(throws: LoginProfileError.self) { try LoginProfile.parse(Data("{\"identity\":{\"id\":\"email-field\"}}".utf8)) }
    }

    @Test("one profile can name an iOS bundle id and an Android package, and serves either app")
    func parsesBothIDs() throws {
        let parsed = try LoginProfile.parse(Data("{\"bundleId\":\"com.example.ios\",\"package\":\"com.example.android\"}".utf8))
        #expect(parsed.isFor("com.example.ios"))
        #expect(parsed.isFor("com.example.android"))
        #expect(!parsed.isFor("com.example.other"))
    }

    @Test("an iOS bundle id comes from the simulator executable, and an Android package from the tree")
    func foregroundApp() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-login-\(UUID().uuidString)")
        let app = root + "/Example.app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.app</string></dict></plist>
        """
        try Data(plist.utf8).write(to: URL(fileURLWithPath: app + "/Info.plist"))
        let executable = app + "/Example"
        try Data().write(to: URL(fileURLWithPath: executable))
        let application = UINode(
            role: .application,
            frame: UIFrame(x: 0, y: 0, width: 200, height: 400),
            native: .ios(IOSNativeAttributes(pid: 42))
        )
        let tree = UITree(platform: .ios, device: "simulator", roots: [application])
        #expect(try ForegroundApp.identifier(in: tree, pathForPID: { $0 == 42 ? executable : nil }) == "com.example.app")
        #expect(throws: ForegroundApp.Failure.self) { try ForegroundApp.identifier(in: tree, pathForPID: { _ in nil }) }

        let android = androidTree(hit: "com.example.app", other: "com.other.app")
        #expect(try ForegroundApp.identifier(in: android, pathForPID: { _ in nil }) == "com.example.app")
        let several = androidTree(hit: nil, other: "com.other.app", second: "com.third.app")
        #expect(throws: ForegroundApp.Failure.self) { try ForegroundApp.identifier(in: several, pathForPID: { _ in nil }) }
        let covered = androidTree(hit: "com.example.app", other: "com.example.ime", keyboard: true)
        #expect(try ForegroundApp.identifier(in: covered, pathForPID: { _ in nil }) == "com.example.app")
    }

    @Test("locate can search for offsider.login.json")
    func locatesLoginFile() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-login-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root + "/app", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: root + "/offsider.login.json"))
        let found = try ProjectGuide.locate(fileName: LoginProfile.fileName, from: root + "/app", home: "/nonexistent")
        #expect(found.path.hasSuffix("/offsider.login.json"))
    }

    private func androidTree(hit: String?, other: String, second: String? = nil, keyboard: Bool = false) -> UITree {
        let hitNode = UINode(
            role: .group,
            frame: UIFrame(x: 0, y: 0, width: 200, height: 400),
            native: .android(AndroidNativeAttributes(package: hit))
        )
        var children = [
            hitNode,
            UINode(
                role: keyboard ? .keyboard : .text,
                frame: keyboard ? UIFrame(x: 0, y: 0, width: 200, height: 400) : UIFrame(x: 0, y: 0, width: 10, height: 10),
                native: .android(AndroidNativeAttributes(package: other))
            ),
        ]
        if let second {
            children.append(UINode(role: .text, frame: UIFrame(x: 0, y: 20, width: 10, height: 10), native: .android(AndroidNativeAttributes(package: second))))
        }
        let root = UINode(
            role: .application,
            frame: UIFrame(x: 0, y: 0, width: 200, height: 400),
            native: .android(AndroidNativeAttributes()),
            children: children
        )
        return UITree(platform: .android, device: "emulator-5554", roots: [root])
    }
}

/// A sign-in screen with a welcome layer underneath the form. Later siblings win the hit test.
enum SignInFixture {
    static func tree(
        emailValue: String? = nil,
        passwordValue: String? = nil,
        submitEnabled: Bool = false,
        extraIdentity: Bool = false,
        extraSubmit: Bool = false,
        coverPassword: Bool = false,
        keyboardNext: Bool = false,
        fullKeyboard: Bool = false,
        lowKeyboard: Bool = false,
        assistantChrome: Bool = false,
        emptyCover: Bool = false,
        omitSubmit: Bool = false,
        submitLabel: String = "Log in",
        identityLabel: String = "Email"
    ) -> UITree {
        var children: [UINode] = [
            FakeUI.node(.button, id: "sign-in-button", label: "Sign in", frame: FakeUI.frame(16, 790, 370, 44)),
            FakeUI.node(.button, id: "create-account", label: "Create account", frame: FakeUI.frame(16, 732, 370, 44)),
            FakeUI.node(.textField, id: "email-field", label: identityLabel, value: emailValue, frame: FakeUI.frame(17, 212, 367, 45)),
        ]
        if extraIdentity {
            children.append(FakeUI.node(.textField, id: "other-email", label: "Email", frame: FakeUI.frame(17, 260, 367, 45)))
        }
        children.append(FakeUI.node(.secureTextField, id: "password-field", label: "Password", value: passwordValue, frame: FakeUI.frame(17, 316, 367, 45)))
        children.append(FakeUI.node(.button, frame: FakeUI.frame(357, 323, 20, 32)))
        if coverPassword {
            children.append(FakeUI.node(.button, id: "cover", label: "Cover", frame: FakeUI.frame(17, 316, 367, 45)))
        }
        children.append(FakeUI.node(.scrollView, frame: FakeUI.frame(16, 375, 370, 80), children: [
            FakeUI.node(.slider, frame: FakeUI.frame(20, 390, 100, 20)),
            FakeUI.node(.slider, frame: FakeUI.frame(200, 390, 100, 20)),
        ]))
        if !omitSubmit {
            children.append(FakeUI.node(.button, id: "login-button", label: submitLabel, frame: FakeUI.frame(16, 732, 370, 44), enabled: submitEnabled))
        }
        if extraSubmit {
            children.append(FakeUI.node(.button, id: "also-login", label: "Log in", frame: FakeUI.frame(16, 500, 370, 44)))
        }
        children.append(FakeUI.node(.button, id: "forgot", label: "Forgot Password", frame: FakeUI.frame(16, 790, 370, 44)))
        children.append(FakeUI.node(.button, id: "back-button", label: "Back", frame: FakeUI.frame(16, 40, 60, 30)))
        children.append(FakeUI.node(.button, id: "feedback", label: "Send feedback", frame: FakeUI.frame(16, 640, 160, 36)))
        children.append(FakeUI.node(.text, label: "Log in", frame: FakeUI.frame(140, 80, 120, 24)))
        children.append(FakeUI.node(.text, label: "Log in", frame: FakeUI.frame(140, 110, 120, 24)))
        if keyboardNext {
            children.append(FakeUI.node(.keyboard, frame: FakeUI.frame(0, 840, 402, 34), children: [
                FakeUI.node(.button, label: "Next", frame: FakeUI.frame(320, 844, 60, 24)),
            ]))
        }
        if fullKeyboard {
            children.append(FakeUI.node(.keyboard, frame: FakeUI.frame(0, 0, 402, 874)))
        }
        if lowKeyboard {
            children.append(FakeUI.node(.keyboard, frame: FakeUI.frame(0, 560, 402, 314)))
        }
        if emptyCover {
            children.append(FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), children: [
                FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874)),
            ]))
        }
        if assistantChrome {
            let bogus = FakeUI.node(.group, frame: FakeUI.frame(0, 274, 402, 1220))
            let assistant = FakeUI.node(.group, id: "SystemInputAssistantView", frame: FakeUI.frame(0, 874, 402, 44), children: [bogus])
            let keys = FakeUI.node(.keyboard, id: "UIKeyboardLayoutStar Preview", frame: FakeUI.frame(0, 918, 402, 226))
            let holder = FakeUI.node(.group, frame: FakeUI.frame(0, 874, 402, 270), children: [assistant, keys])
            children.append(FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), children: [holder]))
        }
        return FakeUI.tree(children)
    }
}
