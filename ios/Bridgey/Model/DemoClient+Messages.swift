import Foundation

#if DEBUG
extension DemoClient {
    private static let minute: Int64 = 60_000

    private static func ago(_ minutes: Int64) -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) - minutes * minute }

    private static var demoThreads: [[String: Any]] {
        [
            ["threadId": 21, "title": "Asha Patel", "participants": [["address": "+447700900123", "name": "Asha Patel"]], "snippet": "Running 10 minutes late, save me a seat", "date": ago(3), "unread": 2, "group": false],
            ["threadId": 18, "title": "Weekend trip", "participants": [["address": "+447700900456", "name": "Ravi"], ["address": "+447700900789", "name": "Sam"]], "snippet": "Sam: I’ll bring the tent", "date": ago(48), "unread": 0, "group": true],
            ["threadId": 15, "title": "Dentist", "participants": [["address": "+447700900321", "name": "Dentist"]], "snippet": "Reminder: check-up on Thursday at 09:40. Reply C to confirm.", "date": ago(60 * 20), "unread": 0, "group": false],
            ["threadId": 9, "title": "Ravi", "participants": [["address": "+447700900456", "name": "Ravi"]], "snippet": "Photo", "date": ago(60 * 30), "unread": 0, "group": false],
            ["threadId": 4, "title": "+44 7700 900654", "participants": [["address": "+447700900654"]], "snippet": "Your parcel is out for delivery today.", "date": ago(60 * 24 * 4), "unread": 0, "group": false],
        ]
    }

    private static func demoMessages(_ thread: Int64) -> [[String: Any]] {
        guard thread == 21 else {
            return [["id": "d\(thread)", "threadId": thread, "direction": "in", "status": "received", "date": ago(60), "address": "+447700900456", "body": "See you soon"]]
        }
        // Newest first, as the library lists them.
        return [
            ["id": "a6", "threadId": 21, "direction": "in", "status": "received", "date": ago(3), "address": "+447700900123", "body": "Running 10 minutes late, save me a seat"],
            ["id": "a5", "threadId": 21, "direction": "in", "status": "received", "date": ago(4), "address": "+447700900123", "body": "Train’s stuck outside Clapham"],
            ["id": "a4", "threadId": 21, "direction": "out", "status": "delivered", "date": ago(15), "address": "+447700900123", "body": "Booked for 7:30 under Patel"],
            ["id": "a3", "threadId": 21, "direction": "in", "status": "received", "date": ago(22), "address": "+447700900123", "body": "Perfect. Can you book the table?"],
            ["id": "a2", "threadId": 21, "direction": "out", "status": "delivered", "date": ago(25), "address": "+447700900123", "body": "Dinner on Friday? The new Sri Lankan place opened"],
        ]
    }

    func demoMessages(deviceID: String, command: [String: Any]) -> [String: Any] {
        let thread = MessagesModel.int(command["threadId"]) ?? 0
        switch command["op"] as? String {
        case "status":
            return ["ok": true, "available": true, "phone": ["read": true, "send": true, "contacts": true, "sims": [["subId": 1, "slot": 0, "label": "EE"]]],
                    "syncing": false, "unread": 2]
        case "threads":
            let unread = command["filter"] as? String == "unread"
            return ["ok": true, "threads": Self.demoThreads.filter { !unread || (MessagesModel.int($0["unread"]) ?? 0) > 0 }, "more": false, "loading": false]
        case "open", "messages":
            let summary = Self.demoThreads.first { MessagesModel.int($0["threadId"]) == thread }
            return ["ok": true, "thread": summary as Any, "messages": Self.demoMessages(thread), "outgoing": [], "older": false, "loading": false,
                    "sims": [], "canSend": true]
        case "contacts":
            return ["ok": true, "searching": false]
        default:
            return ["ok": true]
        }
    }

    /// Screenshots of Messages: `messages` (the conversations; the test opens one for the conversation).
    @MainActor
    static func seedMessages(_ model: AppModel, screen: String) {
        guard screen == "messages", let phone = model.device(pixel) else { return }
        model.setFeature(phone, key: "sms_draft1", on: true)
        model.targetID = pixel
        model.path = [.messages(deviceID: pixel)]
    }
}
#endif
