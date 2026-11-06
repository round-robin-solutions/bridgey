import Foundation

/// sms_draft1 means participation on both platforms: a Mac client is not an SMS provider.
/// Role evidence comes from the authenticated session, never Bonjour names or platform hints.
enum SmsSourceRules {
    static func permitsProvider(_ link: PhoneLinkState?, restricted: Bool) -> Bool {
        guard let link, link.featureStateReceived, !restricted else { return false }
        return !link.remoteHandoffTakeover && link.updateStatus?.platform != .macos
    }

    static func isPhone(_ link: PhoneLinkState?, restricted: Bool) -> Bool {
        guard permitsProvider(link, restricted: restricted), let link else { return false }
        // Older Android peers have no platform status. Their validated sms.status proves the role.
        return link.updateStatus?.platform == .android || link.smsProviderConfirmed
    }

    static func canRequest(_ link: PhoneLinkState?, restricted: Bool) -> Bool {
        isPhone(link, restricted: restricted) && link?.remoteSms == true
    }

    static func acceptsStatus(_ data: Data, link: PhoneLinkState?, restricted: Bool) -> Bool {
        permitsProvider(link, restricted: restricted) && link?.remoteSms == true && decodeSmsStatus(data) != nil
    }
}
