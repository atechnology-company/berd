import SwiftUI
import SwiftData

@main
struct berdApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
            Conversation.self,
            ConversationMessage.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Handle x-callback-url from Shortcuts: expect ?result=<encoded>
                    guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                    if let item = comps.queryItems?.first(where: { $0.name == "result" }), let value = item.value {
                        Task {
                            let decoded = value.removingPercentEncoding ?? value
                            let tmp = FileManager.default.temporaryDirectory
                            let outURL = tmp.appendingPathComponent("berd-pcc-result-\(UUID().uuidString).json")
                            let payload: [String: Any] = ["result": decoded, "receivedAt": ISO8601DateFormatter().string(from: Date())]
                            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                                try? data.write(to: outURL)
                                NotificationCenter.default.post(name: Notification.Name("BerdPCCResultReceived"), object: nil, userInfo: ["fileURL": outURL])
                            }
                        }
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
