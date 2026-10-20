import Foundation

/// What bare `offsider` prints: a person gets the version and the first commands to run; an agent six plain lines.
public enum StartScreen {
    public static let agentText = """
          offsider devices         See devices and their IDs
          offsider doctor          Check this Mac is ready
          offsider init            Teach your agent to use Offsider
          offsider guide           Read a topic in depth
          offsider boot <AVD>      Start an emulator or simulator
          offsider --help          Every command and option

        """

    public static func page(version: String) -> Page {
        Page([
            .person([
                .header(Header(.iPhone, "Offsider", [version])),
                .commands(title: "Get started", [
                    Shortcut("offsider devices", "See devices and their IDs"),
                    Shortcut("offsider doctor", "Check this Mac is ready"),
                    Shortcut("offsider init", "Teach your agent to use Offsider"),
                ]),
                .commands(title: "Go further", [
                    Shortcut("offsider boot <AVD>", "Start an emulator or simulator"),
                    Shortcut("offsider guide", "Read a topic in depth"),
                    Shortcut("offsider --help", "Every command and option"),
                ]),
            ]),
            .agent(agentText),
        ])
    }
}
