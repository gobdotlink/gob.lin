import Foundation

/// What a treasure counts. Every shelf but Secrets is a ladder of thresholds on one number.
public enum HoardShelf: String, CaseIterable, Sendable, Codable {
    case words, dictations, talk, saved, meetings, meetingTime, streak, bigDay, apps, dictionary, people, marks, secrets

    public var title: String {
        switch self {
        case .words: "Words"
        case .dictations: "Dictations"
        case .talk: "Time Dictating"
        case .saved: "Typing Saved"
        case .meetings: "Meetings"
        case .meetingTime: "Meeting Time"
        case .streak: "Longest Streak"
        case .bigDay: "Biggest Day"
        case .apps: "Apps Typed Into"
        case .dictionary: "Dictionary Words"
        case .people: "People Named"
        case .marks: "Meeting Marks"
        case .secrets: "Secrets"
        }
    }

    /// Shelves that only fill while Meetings is on.
    public var needsMeetings: Bool { [.meetings, .meetingTime, .people, .marks].contains(self) }

    /// What `amount` of this shelf's number reads as: "100,000 words", "10 minutes", "3 days in a row".
    /// Time Dictating counts minutes, and Typing Saved and Meeting Time count hours.
    public func phrase(_ amount: Int) -> String {
        let number = amount.formatted()
        func plural(_ one: String, _ many: String) -> String { amount == 1 ? "1 \(one)" : "\(number) \(many)" }
        switch self {
        case .words: return plural("word", "words")
        case .dictations: return plural("dictation", "dictations")
        case .talk: return amount < 60 ? plural("minute", "minutes") : HoardShelf.saved.phrase(amount / 60)
        case .saved, .meetingTime: return plural("hour", "hours")
        case .meetings: return plural("meeting", "meetings")
        case .streak: return amount == 1 ? "1 day" : "\(number) days in a row"
        case .bigDay: return "\(plural("word", "words")) in a day"
        case .apps: return plural("app", "apps")
        case .dictionary: return plural("dictionary word", "dictionary words")
        case .people: return plural("person", "people")
        case .marks: return plural("mark", "marks")
        case .secrets: return number
        }
    }
}

/// What a treasure stands on. Up a shelf the plinth climbs wood to goblinite, so its top reads as precious beside any
/// other shelf's. Secrets stand on amethyst.
public enum HoardMaterial: String, CaseIterable, Sendable {
    case wood, tin, copper, silver, gold, emerald, goblinite, amethyst

    public var name: String { rawValue.capitalized }
    static let ladder: [HoardMaterial] = [.wood, .tin, .copper, .silver, .gold, .emerald, .goblinite]
    /// How precious: the ladder's order, with a secret between gold and emerald.
    var rank: Double { HoardMaterial.ladder.firstIndex(of: self).map(Double.init) ?? 4.5 }
}

/// Treasures found by doing something, not by reaching a number.
public enum HoardSecret: String, CaseIterable, Sendable, Codable {
    case night, early, monologue, marathon, feast, pocket, weekend, fullWeek = "fullweek", juggler, newYear = "newyear"
    case anniversary, halloween, split, cackle, lurker, swarm

    public var requirement: String {
        switch self {
        case .night: "A dictation between 2 and 4 am"
        case .early: "A dictation between 4 and 6 am"
        case .monologue: "500 words in one take"
        case .marathon: "One meeting over 2 hours"
        case .feast: "5 or more voices in one meeting"
        case .pocket: "Dictate from an iPhone"
        case .weekend: "Dictate on a Saturday and the Sunday after"
        case .fullWeek: "Dictate every weekday, Monday to Friday"
        case .juggler: "Dictate into 10 apps in one day"
        case .newYear: "A dictation on 1 January"
        case .anniversary: "One year since your first dictation"
        case .halloween: "A dictation on 31 October"
        case .split: "Dictate in two different tones on one day"
        case .cackle: "Say “ha ha ha” in a dictation"
        case .lurker: "Dictate while a meeting is recording"
        case .swarm: "Ten dictations in ten minutes"
        }
    }
}

public struct Treasure: Sendable, Identifiable, Hashable {
    /// Stable: the ledger keeps it and the sprite is `hoard/<id>.png`.
    public let id: String
    public let shelf: HoardShelf
    /// The number to reach; nil for a secret.
    public let threshold: Int?
    public let secret: HoardSecret?
    public let name: String
    /// The goblin's line when it's found.
    public let line: String
    public fileprivate(set) var material: HoardMaterial = .amethyst

    public var requirement: String { secret?.requirement ?? shelf.phrase(threshold ?? 0) }

    init(_ shelf: HoardShelf, _ threshold: Int, _ name: String, _ line: String) {
        id = "\(shelf.rawValue)-\(threshold)"
        self.shelf = shelf
        self.threshold = threshold
        secret = nil
        self.name = name
        self.line = line
    }

    init(secret: HoardSecret, _ name: String, _ line: String) {
        id = "secret-\(secret.rawValue)"
        shelf = .secrets
        threshold = nil
        self.secret = secret
        self.name = name
        self.line = line
    }
}

public enum Hoard {
    /// Every treasure, shelf by shelf, lowest first. Plinths come from each one's place on its shelf.
    public static let treasures: [Treasure] = {
        var list = catalog
        for shelf in HoardShelf.allCases where shelf != .secrets {
            let indices = list.indices.filter { list[$0].shelf == shelf }
            for (place, index) in indices.enumerated() {
                let step = Double(place * (HoardMaterial.ladder.count - 1)) / Double(max(1, indices.count - 1))
                list[index].material = HoardMaterial.ladder[Int(step.rounded())]
            }
        }
        return list
    }()

    private static let byID = Dictionary(uniqueKeysWithValues: treasures.map { ($0.id, $0) })

    public static func treasure(_ id: String) -> Treasure? { byID[id] }

    public static func shelf(_ shelf: HoardShelf) -> [Treasure] { treasures.filter { $0.shelf == shelf } }

    /// Every treasure `stats` has reached.
    public static func earned(_ stats: HoardStats, now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        let values = Dictionary(uniqueKeysWithValues: HoardShelf.allCases.map { ($0, stats.value($0, calendar: calendar)) })
        let secrets = stats.secrets(now: now, calendar: calendar)
        return Set(treasures.filter { treasure in
            if let secret = treasure.secret { return secrets.contains(secret) }
            return (values[treasure.shelf] ?? 0) >= (treasure.threshold ?? .max)
        }.map(\.id))
    }

    private static let catalog: [Treasure] = [
        // Words
        Treasure(.words, 100, "Throat Cleared", "Ahem. That was the warm-up."),
        Treasure(.words, 1000, "Four Pages", "About four pages you didn’t type."),
        Treasure(.words, 5000, "Chatterbox", "A scroll so long I had to unroll it twice."),
        Treasure(.words, 10000, "Long-Read", "Long enough that someone would bookmark it."),
        Treasure(.words, 25000, "Novella", "Slim, but it counts."),
        Treasure(.words, 50000, "First Draft", "Novel-length. The editing is your problem."),
        Treasure(.words, 100000, "Doorstop", "A book thick enough to hold a door open."),
        Treasure(.words, 250000, "Trilogy", "Three fat books. I made bookends."),
        Treasure(.words, 500000, "Saga", "A saga. I read it by candlelight."),
        Treasure(.words, 1000000, "Millionaire", "A million words. The book bought a top hat."),
        Treasure(.words, 2500000, "Goblin Glider", "Two and a half million words. I don’t walk anywhere now."),
        Treasure(.words, 5000000, "The Unmuted", "Five million words. The book grew wings, and it’s watching."),
        // Dictations
        Treasure(.dictations, 1, "First Take", "One take, one coin. It starts here."),
        Treasure(.dictations, 10, "Pocket Money", "Ten takes. A little stack."),
        Treasure(.dictations, 50, "Two Stacks", "Fifty takes. I’m sorting them by shine."),
        Treasure(.dictations, 100, "Coin Purse", "A hundred takes. I had to get a purse."),
        Treasure(.dictations, 250, "Spilled Purse", "It burst. I’m not picking them all up."),
        Treasure(.dictations, 500, "Heavy Sack", "Five hundred takes. My back hurts."),
        Treasure(.dictations, 1000, "Treasure Chest", "A thousand takes, locked away."),
        Treasure(.dictations, 2500, "Lid Off", "The lid won’t shut any more."),
        Treasure(.dictations, 5000, "Overflowing", "There’s a necklace in there somewhere."),
        Treasure(.dictations, 10000, "Golden Mound", "I drink from a golden cup now."),
        Treasure(.dictations, 25000, "Dragon’s Envy", "A dragon asked me for tips."),
        // Time Dictating
        Treasure(.talk, 10, "Stub", "Ten minutes of talking. A candle stub’s worth."),
        Treasure(.talk, 30, "Taper", "Half an hour. The wick’s barely started."),
        Treasure(.talk, 60, "Chamberstick", "An hour of talking. I carry it to bed."),
        Treasure(.talk, 180, "Three Candles", "Three hours. I lit a few more."),
        Treasure(.talk, 600, "Hourglass", "Ten hours. I flipped it so you wouldn’t have to."),
        Treasure(.talk, 1440, "Lantern", "A whole day of talking, all added up."),
        Treasure(.talk, 3000, "Candelabra", "Fifty hours. Fancy."),
        Treasure(.talk, 6000, "Chandelier", "A hundred hours. The ceiling’s on fire, in a good way."),
        Treasure(.talk, 15000, "Goblin Fire", "Two hundred and fifty hours. This flame doesn’t go out."),
        // Typing Saved
        Treasure(.saved, 1, "Front Page", "An hour you didn’t spend typing. Hold the front page."),
        Treasure(.saved, 4, "Key Kebab", "Four hours saved. I skewered the spare keys."),
        Treasure(.saved, 8, "Retired Typewriter", "A working day you didn’t spend typing. Cobwebs now."),
        Treasure(.saved, 24, "RIP QWERTY", "A whole day of typing, saved. We held a small funeral."),
        Treasure(.saved, 40, "Keycap Pile", "A full work week you didn’t type. I keep the spare keycaps in a heap."),
        Treasure(.saved, 100, "Zap Gauntlet", "A hundred hours your hands didn’t type. They’ve taken up other hobbies."),
        Treasure(.saved, 250, "Space Excalibar", "Only you can pull the spacebar from the stone."),
        Treasure(.saved, 500, "Mounted Keyboard", "Five hundred hours. I hung it on the wall like a stag."),
        Treasure(.saved, 1000, "Gilded Goblin", "A thousand hours saved. They made a statue. Of me, obviously."),
        // Meetings
        Treasure(.meetings, 1, "Ear Trumpet", "Your first meeting. I heard every word."),
        Treasure(.meetings, 5, "Stool", "Five meetings. Pull up a stool."),
        Treasure(.meetings, 10, "Chair", "Ten meetings. You’ve got a regular seat now."),
        Treasure(.meetings, 25, "Meeting Bell", "Twenty-five meetings. Ding ding."),
        Treasure(.meetings, 50, "Round Table", "Fifty meetings. Nobody sits at the head."),
        Treasure(.meetings, 100, "Gavel", "A hundred meetings. Order, order."),
        Treasure(.meetings, 250, "Toastmaster", "Two hundred and fifty meetings. Cheers to the notes."),
        Treasure(.meetings, 500, "War Horn", "Five hundred meetings. Summon the council."),
        Treasure(.meetings, 1000, "Goblin Throne", "A thousand meetings. Sit. Cackle. Rule."),
        // Meeting Time
        Treasure(.meetingTime, 1, "Vial", "An hour of meetings, bottled."),
        Treasure(.meetingTime, 5, "Round Flask", "Five hours. It’s steeping."),
        Treasure(.meetingTime, 10, "Bubbling Flask", "Ten hours. Now it fizzes."),
        Treasure(.meetingTime, 24, "Cauldron", "A whole day in meetings. Something’s brewing."),
        Treasure(.meetingTime, 50, "Low Boil", "Fifty hours. I lit a fire under it."),
        Treasure(.meetingTime, 100, "Potion Rack", "A hundred hours. I’ve started labelling them."),
        Treasure(.meetingTime, 250, "Alembic", "Two hundred and fifty hours, boiled down to the good bits."),
        Treasure(.meetingTime, 500, "Goblin Formula", "Five hundred hours in meetings. One sip and you’d never stop talking."),
        // Longest Streak
        Treasure(.streak, 3, "Sprout", "Three days in a row. Something’s growing."),
        Treasure(.streak, 7, "Toadstool", "A week straight. It sprouted overnight."),
        Treasure(.streak, 14, "Pair", "Two weeks. It brought a friend."),
        Treasure(.streak, 30, "Cluster", "A month without missing a day. They’re everywhere."),
        Treasure(.streak, 50, "Fairy Ring", "Fifty days. Step inside at your own risk."),
        Treasure(.streak, 100, "Giant Toadstool", "A hundred days. The snail is impressed."),
        Treasure(.streak, 200, "Glowshrooms", "Two hundred days. They glow in the dark now."),
        Treasure(.streak, 365, "Mushroom House", "A year without missing a day. I moved in."),
        Treasure(.streak, 730, "Goblin Lair", "Two years without missing a day. Welcome to my lair."),
        // Biggest Day
        Treasure(.bigDay, 1000, "Match", "A thousand words in one day. Struck."),
        Treasure(.bigDay, 2500, "Torch", "Two and a half thousand in a day. Hold it high."),
        Treasure(.bigDay, 5000, "Campfire", "Five thousand in a day. Sit down, tell a story."),
        Treasure(.bigDay, 10000, "Volcano", "Ten thousand words in one day. Stand back."),
        Treasure(.bigDay, 20000, "Pumpkin Bomb", "Twenty thousand words in one day. Kaboom."),
        // Apps Typed Into
        Treasure(.apps, 3, "Iron Key", "Three apps. They let me in."),
        Treasure(.apps, 5, "Key Ring", "Five apps. Jangly."),
        Treasure(.apps, 10, "Skeleton Key", "Ten apps. Opens most things."),
        Treasure(.apps, 25, "Keymaster", "Twenty-five apps. Every door is open to me."),
        // Dictionary Words
        Treasure(.dictionary, 1, "Rough Find", "Your first dictionary word. Something shiny in there."),
        Treasure(.dictionary, 10, "Cut Gem", "Ten words I’ll never mishear."),
        Treasure(.dictionary, 50, "Geode", "Fifty words. Crack one open."),
        Treasure(.dictionary, 100, "Amulet", "A hundred words. I wear it for luck."),
        Treasure(.dictionary, 250, "Crown Jewels", "Two hundred and fifty words. Treat me like royalty."),
        // People Named
        Treasure(.people, 1, "Hello", "The first name I learned. Hi."),
        Treasure(.people, 5, "Portrait", "Five people. I painted one."),
        Treasure(.people, 10, "Pair of Portraits", "Ten people. The gallery’s growing."),
        Treasure(.people, 25, "Wanted", "Twenty-five people. I know their voices anywhere."),
        Treasure(.people, 50, "Masks", "Fifty people. Happy ones and sad ones."),
        Treasure(.people, 100, "Secret Room", "A hundred people named. I know every voice, even the one in the mask."),
        // Meeting Marks
        Treasure(.marks, 1, "Quill", "Your first mark. Noted."),
        Treasure(.marks, 25, "Inkpot", "Twenty-five marks. I’m running low on ink."),
        Treasure(.marks, 100, "Wax Seal", "A hundred marks. Signed and sealed."),
        Treasure(.marks, 250, "Razor Bats", "Two hundred and fifty marks. Sharp ones."),
        // Secrets
        Treasure(secret: .night, "Night Goblin", "Dictating at this hour? Me too."),
        Treasure(secret: .early, "Early Goblin", "Before six? Who hurt you?"),
        Treasure(secret: .monologue, "Monologue", "Five hundred words without a breath."),
        Treasure(secret: .marathon, "Marathon", "Two hours in one meeting. Go stretch."),
        Treasure(secret: .feast, "Full Table", "Five voices in one meeting. Save me a leg."),
        Treasure(secret: .pocket, "Pocket Goblin", "I fit in your pocket now."),
        Treasure(secret: .weekend, "Weekend Warrior", "Rest is for elves."),
        Treasure(secret: .fullWeek, "Full Week", "Monday to Friday, every single day."),
        Treasure(secret: .juggler, "Juggler", "Ten apps in a day. Keep them all in the air."),
        Treasure(secret: .newYear, "New Year’s Words", "First words of the year."),
        Treasure(secret: .anniversary, "Anniversary", "A year together. Have some cake."),
        Treasure(secret: .halloween, "Trick or Treat", "Spooky words. I kept the good sweets."),
        Treasure(secret: .split, "Split Personality", "Two tones in one day. We’re both very proud of you."),
        Treasure(secret: .cackle, "Cackle", "Ha ha ha. That’s my line."),
        Treasure(secret: .lurker, "Lurker", "Dictating mid-meeting. Sneaky. I like it."),
        Treasure(secret: .swarm, "Bat Swarm", "Ten in ten minutes. They all came out at once."),
    ]
}
