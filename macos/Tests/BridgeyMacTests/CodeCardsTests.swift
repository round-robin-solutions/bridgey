import Foundation
import XCTest
@testable import BridgeyMac

/// Codes from email (docs/codes-from-email.md) and the code cards' order, duplicates and marks, SMS included.
/// Every message here is synthetic.
final class CodeCardsTests: XCTestCase {
    private let gmail = "com.google.android.gm"
    private let spark = "com.readdle.spark"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, code: String, sender: String, posted: TimeInterval = 0, arrival: Int,
                      received: TimeInterval? = nil, sources: [CodeSource] = [CodeSource(channel: .sms, app: "Messages")],
                      device: String = "OnePlus 11") -> LiveCodeCard {
        LiveCodeCard(id: id, code: code, sender: sender, deviceName: device,
                     receivedAt: start.addingTimeInterval(received ?? posted), postedAt: start.addingTimeInterval(posted),
                     arrival: arrival, sources: sources)
    }

    // MARK: Candidate, mail branch

    func testMailNotificationIsACandidateOnlyWithTheSwitchAndTheMark() {
        let preview = "Your GitHub sign-in code\nUse 482913 to verify your identity. It expires in 10 minutes."
        let candidate = codeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: "Your GitHub sign-in code",
                                      emailApp: true, preview: preview, emailCodes: true)
        XCTAssertEqual(candidate, .email(preview))
        XCTAssertTrue(candidate?.isEmail == true)
        // Also read codes in email off.
        XCTAssertNil(codeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: "x", emailApp: true, preview: preview, emailCodes: false))
        // No emailApp mark (an old phone, a group summary, or a Mac without the key): never read.
        XCTAssertNil(codeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: preview, emailApp: nil, preview: nil, emailCodes: true))
        XCTAssertNil(codeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: preview, emailApp: false, preview: preview, emailCodes: true))
        // Marked, but not one of the four mail apps.
        XCTAssertNil(codeCandidate(packageName: "com.example.mail", smsDefaultApp: false, redacted: nil, text: preview, emailApp: true, preview: preview, emailCodes: true))
        // Redacted by Android.
        XCTAssertNil(codeCandidate(packageName: gmail, smsDefaultApp: false, redacted: true, text: preview, emailApp: true, preview: preview, emailCodes: true))
        // Too long: never cut.
        let long = preview + String(repeating: " filler", count: 90)
        XCTAssertGreaterThan(long.utf16.count, 600)
        XCTAssertNil(codeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: "x", emailApp: true, preview: long, emailCodes: true))
        // No code word near the number.
        XCTAssertNil(codeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: "x", emailApp: true,
                                   preview: "Order 482913 has shipped and arrives on Tuesday.", emailCodes: true))
        // Marketing.
        XCTAssertNil(codeCandidate(packageName: spark, smsDefaultApp: false, redacted: nil, text: "x", emailApp: true,
                                   preview: "Use code SAVE50 at checkout for 50% off. Unsubscribe any time.", emailCodes: true))
        // No preview: the notification text is read.
        XCTAssertEqual(codeCandidate(packageName: spark, smsDefaultApp: false, redacted: nil, text: " Your verification code is 730164 ",
                                     emailApp: true, preview: nil, emailCodes: true),
                       .email("Your verification code is 730164"))
        // The Bool wrapper keeps the old call sites.
        XCTAssertTrue(isCodeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: "x", emailApp: true, preview: preview, emailCodes: true))
        XCTAssertFalse(isCodeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: preview))
    }

    func testSmsStaysASmsCandidateWhateverTheEmailSwitch() {
        XCTAssertEqual(codeCandidate(packageName: "com.google.android.apps.messaging", smsDefaultApp: true, redacted: nil,
                                     text: "482913 is your OTP", emailCodes: false), .sms("482913 is your OTP"))
        XCTAssertEqual(knownMailPackages, ["com.google.android.gm", "com.microsoft.office.outlook", "ch.protonmail.android", "com.readdle.spark"])
    }

    // MARK: Email pre-check (the full rule is checked against email_guard.py in EmailCodeRulesTests)

    func testEmailPrecheckNeedsACodeWordNearTheToken() {
        XCTAssertTrue(emailCodePrecheck("Your Microsoft account security code is 482913."))
        XCTAssertTrue(emailCodePrecheck("482913\n\nEnter this one-time passcode to sign in."))
        XCTAssertTrue(emailCodePrecheck("Ваш код подтверждения: 730164"))
        XCTAssertTrue(emailCodePrecheck("आपका ओटीपी 482913 है"))
        XCTAssertTrue(emailCodePrecheck("Login attempt. PIN 4821."))
        XCTAssertTrue(emailCodePrecheck("Confirm with 482 913 within 5 minutes"), "split codes count")
        XCTAssertFalse(emailCodePrecheck("No digits here, just a verification email."), "no token")
        XCTAssertFalse(emailCodePrecheck("Invoice INV-2026 for order 4417 is attached."), "no code word")
        // A code word further than 100 characters away does not count.
        let far = "Your code" + String(repeating: " and some more text", count: 6) + " 482913"
        XCTAssertFalse(emailCodePrecheck(far))
        XCTAssertEqual(emailCodeWordWindow, 100)
        // Words inside a longer word do not count; "login" alone is not a code word.
        XCTAssertFalse(emailCodePrecheck("Encoded order 482913 shipped"))
        XCTAssertFalse(emailCodePrecheck("Login alert: new sign-in from Chrome, customer ID 5531209"))
    }

    func testEmailPrecheckRefusesMarketingDeadCodesLinksAndMeetings() {
        XCTAssertFalse(emailCodePrecheck("Promo code WELCOME10 gives you 10 off your first order."))
        XCTAssertFalse(emailCodePrecheck("Your referral code is RAHUL2026. Share it with friends."))
        XCTAssertFalse(emailCodePrecheck("Gift code 4821-9930 inside"))
        // Unsubscribe with a marketing phrase anywhere: refused even with a code word.
        XCTAssertFalse(emailCodePrecheck("Verify your email to get 20% off. Code 482913. Unsubscribe"))
        // "Use code" is not marketing: real code mails say it.
        XCTAssertTrue(emailCodePrecheck("Use code 482913 to sign in to Slack."))
        XCTAssertTrue(emailCodePrecheck("Your verification code is 482913. Unsubscribe from these alerts."))
        XCTAssertFalse(emailCodePrecheck("Your code 551204 has expired. Request a new one."), "dead code")
        XCTAssertFalse(emailCodePrecheck("Join Zoom meeting. Meeting ID 812 3345 9921. Passcode: 81329"), "meeting passcode")
        XCTAssertFalse(emailCodePrecheck("Verify here: https://example.com/verify/a8F3k29Q code below"), "link token")
        XCTAssertTrue(emailCodePrecheck("Sign in with your one-time code 7Q3-9XT"), "split letters and digits")
    }

    func testEmailTextJoinsDigitBoxes() {
        XCTAssertEqual(normaliseEmailText("Your code is 4 8 2 9 1 3"), "Your code is 482913")
        XCTAssertEqual(normaliseEmailText("Your code is 48 29 13"), "Your code is 482913")
        XCTAssertEqual(normaliseEmailText("OTP 6-0-2-7-3-1."), "OTP 602731.")
        XCTAssertEqual(normaliseEmailText("Due 31-10-26, call 1 2"), "Due 31-10-26, call 1 2", "dates and short runs stay")
        let gmail = "com.google.android.gm"
        XCTAssertEqual(codeCandidate(packageName: gmail, smsDefaultApp: false, redacted: nil, text: "x", emailApp: true,
                                     preview: "Your verification code is 4 8 2 9 1 3", emailCodes: true),
                       .email("Your verification code is 482913"))
    }

    // MARK: Order

    func testPostTimeIsClampedNearTheReceiptTime() {
        let received = start
        let ms = { (offset: TimeInterval) in Int64((received.timeIntervalSince1970 + offset) * 1000) }
        XCTAssertEqual(CodeCards.postedAt(phoneMillis: ms(-30), receivedAt: received), received.addingTimeInterval(-30))
        XCTAssertEqual(CodeCards.postedAt(phoneMillis: ms(-15 * 60), receivedAt: received), received.addingTimeInterval(-15 * 60))
        XCTAssertEqual(CodeCards.postedAt(phoneMillis: ms(60), receivedAt: received), received.addingTimeInterval(60))
        XCTAssertEqual(CodeCards.postedAt(phoneMillis: ms(-15 * 60 - 1), receivedAt: received), received, "a phone clock far behind")
        XCTAssertEqual(CodeCards.postedAt(phoneMillis: ms(61), receivedAt: received), received, "a phone clock far ahead")
        XCTAssertEqual(CodeCards.postedAt(phoneMillis: 0, receivedAt: received), received)
    }

    func testOutOfOrderDeliveryIsSortedByPostTimeThenArrival() {
        // B was posted after A but reached the Mac first.
        let b = card("b", code: "222222", sender: "Bank", posted: 20, arrival: 1)
        let a = card("a", code: "111111", sender: "Shop", posted: 10, arrival: 2)
        XCTAssertEqual(CodeCards.ordered([b, a]).map(\.id), ["b", "a"])
        // Same post time: the later arrival is newer.
        let c = card("c", code: "333333", sender: "Bank", posted: 20, arrival: 3)
        XCTAssertEqual(CodeCards.ordered([b, c, a]).map(\.id), ["c", "b", "a"])
        XCTAssertTrue(CodeCards.isNewer(c, than: b))
        XCTAssertFalse(CodeCards.isNewer(b, than: c))
    }

    func testAtMostFiveLiveCardsAreKeptNewestFirst() {
        let cards = (1...7).map { card("c\($0)", code: "48291\($0)", sender: "S\($0)", posted: TimeInterval($0), arrival: $0) }
        XCTAssertEqual(CodeCards.kept(cards, now: start.addingTimeInterval(10)).map(\.id), ["c7", "c6", "c5", "c4", "c3"])
        XCTAssertEqual(CodeCards.kept(cards, now: start.addingTimeInterval(600 + 3.5)).map(\.id), ["c7", "c6", "c5", "c4"], "expired ones go")
    }

    // MARK: Service

    func testServiceKeys() {
        XCTAssertEqual(codeServiceKey("AX-HDFCBK-S"), "hdfcbk")
        XCTAssertEqual(codeServiceKey("JD-SBIINB"), "sbiinb")
        XCTAssertEqual(codeServiceKey("GitHub"), "github")
        XCTAssertEqual(codeServiceKey("Microsoft account team"), "microsoft")
        XCTAssertEqual(codeServiceKey("The Google Accounts team"), "google")
        XCTAssertEqual(codeServiceKey("Slack via no-reply"), "slack")
        XCTAssertEqual(codeServiceKey("+91 98765 43210"), "")
        XCTAssertEqual(codeServiceKey("  "), "")
        XCTAssertTrue(codeServicesMatch(codeServiceKey("HDFC Bank"), codeServiceKey("AX-HDFCBK")), "same first four")
        XCTAssertTrue(codeServicesMatch("github", "githubcom"), "prefix")
        XCTAssertTrue(codeServicesMatch("", "github"), "unknown matches any")
        XCTAssertFalse(codeServicesMatch("github", "google"))
        XCTAssertFalse(codeServicesMatch("abc", "abd"))
    }

    func testSenderIsTheTitleUnlessItIsASummary() {
        XCTAssertEqual(codeSender(title: " GitHub ", applicationName: "Gmail"), "GitHub")
        XCTAssertEqual(codeSender(title: "", applicationName: "Gmail"), "Gmail")
        XCTAssertEqual(codeSender(title: "2 new emails", applicationName: "Spark"), "Spark")
    }

    // MARK: Duplicates

    func testSmsThenEmailIsADuplicateThatAddsTheChannel() {
        var live = [card("sms", code: "482913", sender: "AX-HDFCBK", arrival: 1)]
        let arrival = CodeCards.arrival(code: "482913", serviceKey: codeServiceKey("HDFC Bank"), posted: start.addingTimeInterval(5),
                                        arrival: 2, live: live, now: start.addingTimeInterval(6))
        XCTAssertEqual(arrival, .duplicate(cardID: "sms"))
        live[0].add(CodeSource(channel: .email, app: "Gmail"))
        XCTAssertEqual(codeSourceLine(live[0].sources), "by text, also by email")
    }

    func testEmailThenSmsIsADuplicate() {
        var live = [card("mail", code: "482 913", sender: "HDFC Bank", arrival: 1, sources: [CodeSource(channel: .email, app: "Gmail")])]
        XCTAssertEqual(CodeCards.arrival(code: "482913", serviceKey: codeServiceKey("VM-HDFCBK-T"), posted: start, arrival: 2,
                                         live: live, now: start.addingTimeInterval(1)), .duplicate(cardID: "mail"))
        live[0].add(CodeSource(channel: .sms, app: "Messages"))
        XCTAssertEqual(codeSourceLine(live[0].sources), "by email, also by text")
    }

    func testGmailThenSparkWithOneAccountIsOneCard() {
        var live = [card("g", code: "730164", sender: "GitHub", arrival: 1, sources: [CodeSource(channel: .email, app: "Gmail")])]
        XCTAssertEqual(CodeCards.arrival(code: "730164", serviceKey: codeServiceKey("GitHub"), posted: start, arrival: 2,
                                         live: live, now: start.addingTimeInterval(2)), .duplicate(cardID: "g"))
        live[0].add(CodeSource(channel: .email, app: "Spark"))
        live[0].add(CodeSource(channel: .email, app: "spark"))
        XCTAssertEqual(live[0].sources.count, 2, "one entry per mail app")
        XCTAssertEqual(codeSourceLine(live[0].sources), "by email, Gmail and Spark")
    }

    func testTheSameCodeFromTwoPhonesIsADuplicate() {
        let live = [card("p1", code: "482913", sender: "AX-HDFCBK", arrival: 1, device: "OnePlus 11")]
        XCTAssertEqual(CodeCards.arrival(code: "482913", serviceKey: codeServiceKey("AX-HDFCBK"), posted: start, arrival: 2,
                                         live: live, now: start.addingTimeInterval(3)), .duplicate(cardID: "p1"))
    }

    func testDifferentCodesFromOneServiceAreTwoCardsAndTheNewerReplaces() {
        let live = [card("old", code: "111111", sender: "GitHub", posted: 0, arrival: 1)]
        let arrival = CodeCards.arrival(code: "222222", serviceKey: codeServiceKey("GitHub"), posted: start.addingTimeInterval(60),
                                        arrival: 2, live: live, now: start.addingTimeInterval(61))
        XCTAssertEqual(arrival, .fresh(late: false, replaces: "old"))
        // A different service is neither a duplicate nor replaced.
        XCTAssertEqual(CodeCards.arrival(code: "111111", serviceKey: codeServiceKey("Google"), posted: start.addingTimeInterval(60),
                                         arrival: 3, live: live, now: start.addingTimeInterval(61)),
                       .fresh(late: false, replaces: nil))
    }

    func testTheSameCodeAfterTenMinutesIsNew() {
        let live = [card("old", code: "482913", sender: "GitHub", arrival: 1)]
        XCTAssertEqual(CodeCards.arrival(code: "482913", serviceKey: codeServiceKey("GitHub"), posted: start.addingTimeInterval(600),
                                         arrival: 2, live: live, now: start.addingTimeInterval(600)),
                       .fresh(late: false, replaces: nil))
    }

    func testAnOlderCodeArrivingLateIsMarkedLateAndOlder() {
        let newer = card("new", code: "222222", sender: "GitHub", posted: 30, arrival: 1)
        let arrival = CodeCards.arrival(code: "111111", serviceKey: codeServiceKey("GitHub"), posted: start.addingTimeInterval(10),
                                        arrival: 2, live: [newer], now: start.addingTimeInterval(40))
        XCTAssertEqual(arrival, .fresh(late: true, replaces: nil))
        let late = card("late", code: "111111", sender: "GitHub", posted: 10, arrival: 2, received: 40)
        XCTAssertEqual(CodeCards.marks([newer, late]), ["new": .latest, "late": .older])
        XCTAssertEqual(CodeCards.ordered([late, newer]).map(\.id), ["new", "late"])
    }

    // MARK: Marks and text

    func testLatestAndOlderMarks() {
        let a = card("a", code: "111111", sender: "GitHub", posted: 0, arrival: 1)
        let b = card("b", code: "222222", sender: "GitHub", posted: 60, arrival: 2)
        let c = card("c", code: "333333", sender: "GitHub", posted: 90, arrival: 3)
        let other = card("o", code: "444444", sender: "HDFC Bank", posted: 120, arrival: 4)
        XCTAssertEqual(CodeCards.marks([a, b, c, other]), ["a": .older, "b": .older, "c": .latest])
        XCTAssertEqual(CodeCards.marks([other]), [:], "a lone card has no mark")
        XCTAssertEqual(CodeCardMark.latest.text, "Latest, use this one")
        XCTAssertEqual(CodeCardMark.older.text, "Older, replaced")
    }

    func testRelativeTime() {
        XCTAssertEqual(codeRelativeTime(start, now: start), "now")
        XCTAssertEqual(codeRelativeTime(start, now: start.addingTimeInterval(9.9)), "now")
        XCTAssertEqual(codeRelativeTime(start.addingTimeInterval(30), now: start), "now", "a phone clock a little ahead")
        XCTAssertEqual(codeRelativeTime(start, now: start.addingTimeInterval(40.6)), "40 s ago")
        XCTAssertEqual(codeRelativeTime(start, now: start.addingTimeInterval(119)), "1 min ago")
        XCTAssertEqual(codeRelativeTime(start, now: start.addingTimeInterval(150)), "2 min ago")
        XCTAssertEqual(codeRelativeTime(start, now: start.addingTimeInterval(7_300)), "2 h ago")
        let older = card("o", code: "111111", sender: "GitHub", posted: 0, arrival: 1)
        XCTAssertEqual(codeReplacesLine(older, now: start.addingTimeInterval(75)), "Replaces the code from 1 min ago")
        XCTAssertEqual(codeReplacesLine(older, now: start.addingTimeInterval(3)), "Replaces the code from a moment ago")
        var item = NotificationHistoryItem(id: "h", packageName: gmail, applicationName: "Gmail", title: "GitHub", text: "Sent a one-time code", receivedAt: start)
        XCTAssertNil(item.codeAge(now: start.addingTimeInterval(120)), "not a code row")
        item.code = true
        XCTAssertEqual(item.codeAge(now: start.addingTimeInterval(120)), "2 min ago")
        XCTAssertNil(item.codeAge(now: start.addingTimeInterval(3_600)), "after an hour the date shows")
    }

    func testSourceLines() {
        XCTAssertEqual(codeSourceLine([CodeSource(channel: .sms, app: "Messages")]), "by text")
        XCTAssertEqual(codeSourceLine([CodeSource(channel: .email, app: "Gmail")]), "by email, Gmail")
        XCTAssertEqual(codeSourceLine([CodeSource(channel: .email, app: "Gmail"), CodeSource(channel: .email, app: "Spark")]), "by email, Gmail and Spark")
        XCTAssertEqual(codeSourceLine([CodeSource(channel: .email, app: "Gmail"), CodeSource(channel: .email, app: "Outlook"),
                                       CodeSource(channel: .email, app: "Spark")]), "by email, Gmail, Outlook and Spark")
        XCTAssertEqual(codeSourceLine([CodeSource(channel: .sms, app: ""), CodeSource(channel: .email, app: "Gmail")]), "by text, also by email")
        XCTAssertEqual(codeSourceLine([CodeSource(channel: .email, app: "Gmail"), CodeSource(channel: .sms, app: "")]), "by email, also by text")
        XCTAssertEqual(codeSourceLine([CodeSource(channel: .email, app: "")]), "by email")
        XCTAssertEqual(codeSourceLine([CodeSource(channel: .sms, app: "Messages"), CodeSource(channel: .sms, app: "Truecaller")]), "by text")
    }

    func testCardDetailLines() {
        var older = card("o", code: "111111", sender: "GitHub", posted: 0, arrival: 1, sources: [CodeSource(channel: .email, app: "Gmail")])
        XCTAssertEqual(CodeCards.detail(older, mark: .older, now: start.addingTimeInterval(130)),
                       "Older, replaced\nFrom GitHub on OnePlus 11\nby email, Gmail \u{00B7} 2 min ago")
        older.copiedAt = start.addingTimeInterval(120)
        XCTAssertEqual(CodeCards.detail(older, mark: nil, now: start.addingTimeInterval(130)),
                       "Copied. Clears in 50 s.\nby email, Gmail \u{00B7} 2 min ago")
    }
}
