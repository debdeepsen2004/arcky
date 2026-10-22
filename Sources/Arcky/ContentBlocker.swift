import Foundation
import WebKit

/// Arcky's built-in ad and tracker blocker, compiled into a WebKit content rule list.
/// Requests to known ad and tracking domains are blocked when a page loads them from
/// another site, and common ad containers are hidden. Sites can be allowed individually.
enum ContentBlocker {
    /// Third-party ad networks, trackers and analytics.
    static let blockedDomains = [
        // Google ads and analytics
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagservices.com", "adservice.google.com", "pagead2.googlesyndication.com",
        "googletagmanager.com", "app-measurement.com", "2mdn.net", "imasdk.googleapis.com",
        // Social trackers
        "connect.facebook.net", "pixel.facebook.com", "ads-twitter.com", "analytics.twitter.com",
        "static.ads-twitter.com", "ads.linkedin.com", "px.ads.linkedin.com", "snap.licdn.com",
        "analytics.tiktok.com", "ads.tiktok.com", "ct.pinterest.com", "sc-static.net", "tr.snapchat.com",
        "bat.bing.com", "clarity.ms", "ads.reddit.com", "alb.reddit.com",
        // Ad exchanges and networks
        "adnxs.com", "adsrvr.org", "advertising.com", "amazon-adsystem.com", "criteo.com", "criteo.net",
        "taboola.com", "outbrain.com", "outbrainimg.com", "pubmatic.com", "rubiconproject.com",
        "openx.net", "casalemedia.com", "indexww.com", "smartadserver.com", "sharethrough.com",
        "teads.tv", "triplelift.com", "yieldmo.com", "media.net", "contextweb.com", "bidswitch.net",
        "adform.net", "adition.com", "zemanta.com", "revcontent.com", "mgid.com", "propellerads.com",
        "popads.net", "popcash.net", "adsterra.com", "exoclick.com", "juicyads.com", "trafficjunky.net",
        "33across.com", "gumgum.com", "sovrn.com", "lijit.com", "districtm.io", "adkernel.com",
        "spotxchange.com", "springserve.com", "lkqd.net", "undertone.com", "kargo.com",
        "moatads.com", "adsafeprotected.com", "doubleverify.com", "serving-sys.com", "flashtalking.com",
        "adroll.com", "quantserve.com", "quantcount.com", "scorecardresearch.com", "bluekai.com",
        "krxd.net", "demdex.net", "everesttech.net", "omtrdc.net", "2o7.net", "agkn.com", "rlcdn.com",
        "tapad.com", "liadm.com", "crwdcntrl.net", "exelator.com", "eyeota.net", "mathtag.com",
        "turn.com", "w55c.net", "adsymptotic.com", "bidr.io", "zeotap.com", "id5-sync.com",
        "adgrx.com", "yieldlab.net", "adhigh.net", "smaato.net", "inmobi.com", "applovin.com",
        "unityads.unity3d.com", "chartboost.com", "vungle.com", "adcolony.com", "ironsrc.com",
        // Analytics and session recording
        "hotjar.com", "hotjar.io", "mouseflow.com", "fullstory.com", "crazyegg.com", "luckyorange.com",
        "inspectlet.com", "smartlook.com", "quantummetric.com", "contentsquare.net", "clicktale.net",
        "newrelic.com", "nr-data.net", "segment.io", "segment.com", "mixpanel.com", "amplitude.com",
        "heapanalytics.com", "kissmetrics.com", "chartbeat.com", "chartbeat.net", "parsely.com",
        "statcounter.com", "histats.com", "mc.yandex.ru", "an.yandex.ru", "top-fwz1.mail.ru",
        // Consent-wall and misc trackers
        "branch.io", "app.link", "adjust.com", "appsflyer.com", "kochava.com", "onesignal.com",
    ]

    /// Generic ad containers hidden on every page.
    static let hiddenSelectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^='google_ads_iframe']", "[id^='div-gpt-ad']",
        ".trc_rbox_container", ".OUTBRAIN", "[data-ad-slot]", "amp-ad", "amp-embed[type='taboola']",
    ]

    static let identifier = "ArckyContentBlocker"

    /// The rules as WebKit's content blocker JSON. Sites in `allowedSites` are left alone.
    static func rulesJSON(allowedSites: [String]) -> String {
        var rules: [[String: Any]] = blockedDomains.map { domain in
            [
                "trigger": [
                    // Matches the domain and its subdomains in any scheme (AdGuard's "||domain^").
                    "url-filter": "^[^:]+://+([^:/]+\\.)?" + NSRegularExpression.escapedPattern(for: domain) + "[:/]",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        // WebKit applies page-wide hiding rules as one shared stylesheet that
        // "ignore-previous-rules" doesn't undo, so allowed sites are excluded here directly.
        var hideTrigger: [String: Any] = ["url-filter": ".*"]
        if !allowedSites.isEmpty { hideTrigger["unless-domain"] = allowedSites.map { "*" + $0 } }
        rules.append([
            "trigger": hideTrigger,
            "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")],
        ])
        if !allowedSites.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": allowedSites.map { "*" + $0 }],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(data: data, encoding: .utf8)!
    }

    static func compile(allowedSites: [String]) async throws -> WKContentRuleList? {
        try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: rulesJSON(allowedSites: allowedSites)
        )
    }
}
