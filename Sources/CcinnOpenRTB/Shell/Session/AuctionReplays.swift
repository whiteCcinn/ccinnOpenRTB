import Foundation
import RTBKit

/// Rendering a bid again re-fires its auction's win, billing and impressions: the simulator allows it as a replay and says
/// so (AdTech review). Counts the plays (renders and Lose) of each auction — its `${AUCTION_ID}` — and the notices (win,
/// billing, loss) sent for it in Real mode, for this session. Bounded: at most `capacity` auctions are tracked; later ones
/// count as first plays.
struct AuctionReplays: Sendable {
    /// Notices sent for one auction, for the Real-mode confirmation's warning.
    struct SentNotices: Equatable, Sendable {
        var auctionID: String
        var count: Int
    }

    static let capacity = 10_000
    /// The tracker categories that are the auction's notices (OpenRTB win, billing and loss notices).
    static let noticeCategories: Set<TrackerCategory> = [.win, .billing, .loss]

    private var plays: [String: Int] = [:]
    private var sent: [String: Int] = [:]

    /// Records a play of `auction` and returns its replay number: 0 for the auction's first play, then 1, 2, …
    mutating func play(_ auction: String) -> Int {
        guard let previous = plays[auction] else {
            if plays.count < Self.capacity { plays[auction] = 1 }
            return 0
        }
        plays[auction] = previous &+ 1
        return previous
    }

    mutating func noteSent(_ count: Int, auction: String) {
        guard count > 0, sent[auction] != nil || sent.count < Self.capacity else { return }
        sent[auction, default: 0] &+= count
    }

    /// The notices already sent for `auction` this session; `nil` when none were.
    func sentNotices(auction: String, auctionID: String) -> SentNotices? {
        guard let count = sent[auction], count > 0 else { return nil }
        return SentNotices(auctionID: auctionID, count: count)
    }

    /// `bid 0.0`, or `bid 0.0 · replay 2`: the root of every network source of a play.
    static func sourceRoot(candidateID: String, replay: Int) -> String {
        "bid \(candidateID)" + (replay > 0 ? " · replay \(replay)" : "")
    }

    /// A source written from the plain root (`bid 0.0 › …`, by the tracking plan) carried onto the play's root.
    static func source(_ source: String, candidateID: String, replay: Int) -> String {
        guard replay > 0 else { return source }
        let plain = "bid \(candidateID)"
        let root = sourceRoot(candidateID: candidateID, replay: replay)
        if source == plain { return root }
        if source.hasPrefix(plain + " › ") { return root + source.dropFirst(plain.count) }
        return source
    }
}
