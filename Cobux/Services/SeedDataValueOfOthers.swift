import SwiftUI
import SwiftData

extension SeedData {
    static func seedValueOfOthers(modelContext: ModelContext) {
        // Check if book already exists to avoid duplicates
        let fetchDescriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.title == "The Value of Others" })
        if let existing = try? modelContext.fetch(fetchDescriptor), !existing.isEmpty {
            // Backfill the cover for installs seeded before covers existed.
            if let existingBook = existing.first, existingBook.coverImageURL == nil {
                existingBook.coverImageURL = "https://covers.openlibrary.org/b/id/15131327-L.jpg"
                try? modelContext.save()
            }
            return
        }

        let book = Book(
            title: "The Value of Others",
            author: "Orion Taraban",
            coverColorHex: "#7F1D1D", // Deep crimson, distinct from 12 Rules' amber and Beyond Order's navy
            coverImageURL: "https://covers.openlibrary.org/b/id/15131327-L.jpg"
        )

        modelContext.insert(book)

        // --- Chapters ---
        let chapters = [
            Chapter(title: "Chapter 1: Relationships are the media in which value is transacted",
                    summary: "Relationships form when people exchange unequal goods of comparable value; people move toward each other not because they want the same things but because each has what the other lacks. Value itself isn't objective — it's the output of an unconscious 'covert calculator' that weighs goal-relevance and information, then surfaces as an emotion (desire, in sexual relationships) that motivates action. Because this valuation process is largely unconscious and shaped early by the idiosyncrasies of our home environment, people are often unaware of what they truly value and can end up desiring partners at odds with their own conscious goals.",
                    keyLessons: ["A relationship exists only where value is actually being exchanged; no transaction, no relationship.", "Desire is simply the felt output of an unconscious value calculation — it reveals what you actually prioritize, not what you say you want.", "Your early home environment trains your 'valuation algorithm,' which is why awareness alone rarely changes who you're attracted to."],
                    chapterNumber: 1),
            Chapter(title: "Chapter 2: Sexual relationships are transacted in the sexual marketplace",
                    summary: "The sexual marketplace is everywhere, not confined to bars or apps, and Taraban models it as a dock where 'captains' — who build a lifestyle, master themselves, and plot a life course — attract 'passengers' who inspect the ship, test the captain, and examine the itinerary before boarding. Historically men have been captains and women passengers, but modern women can occupy either role, which creates the 'two-body problem': female captains struggle to find male partners willing to trade their own captaincy for a passenger's seat. All relationships, however brief or lasting, pass through the same three stages: attraction, negotiation, and maintenance.",
                    keyLessons: ["Becoming a 'captain' — building a lifestyle, mastering yourself, and plotting a course — takes roughly a decade and is the real precondition for attracting quality long-term partners.", "Passengers vet captains through inspection, testing, and interrogating the itinerary, mostly before the captain even notices them.", "Modern career success creates the two-body problem: male captains rarely trade their captaincy for a female captain's passenger seat."],
                    chapterNumber: 2),
            Chapter(title: "Chapter 3: Everyone has a value in the sexual marketplace",
                    summary: "Everyone carries a sexual marketplace value (SMV), but it takes several distinct forms: normalized SMV (how closely someone matches a culture's beauty archetype), perceived SMV (how attractive a specific person seems to a specific observer), and transacted SMV (the median value of partners someone has actually secured — sex for men, commitment for women). The chapter also reframes the sexual double standard as an economic artifact rather than a purely cultural one: outcomes achieved through effort and skill are valued more highly than outcomes achieved through inaction.",
                    keyLessons: ["Perceived SMV — how you come across to one specific person — drives real-world outcomes far more than any abstract, 'objective' attractiveness.", "A man's transacted SMV is the median attractiveness of women he's had sex with; a woman's is the median attractiveness of men from whom she's secured commitment.", "The sexual double standard persists because effortless outcomes are valued less than outcomes that require effort — not simply because of patriarchal culture."],
                    chapterNumber: 3),
            Chapter(title: "Chapter 4: Everyone is trying to negotiate their best possible offer",
                    summary: "Marketplaces channel self-interest into prosocial behavior, and the sexual marketplace works the same way — the 'hopeful necessity' of negotiating for sexual opportunity is actually the primary engine behind most self-improvement. Antagonism and competition make negotiation unavoidable: men are incentivized to trade resources for sexual opportunity while women trade sexual opportunity for resources, and the marginal utility of each good differs sharply by sex. This produces four distinct optimal negotiation strategies for male captains, female passengers, female captains, and male passengers.",
                    keyLessons: ["Never having to negotiate for sex would eliminate the incentive behind most sublimated, prosocial self-improvement.", "Men and women trade in fundamentally asymmetric currencies — resources versus sexual opportunity — which drives most of their differing dating incentives.", "Optionality is a double-edged sword: everyone in the sexual marketplace is simultaneously a buyer and a seller."],
                    chapterNumber: 4),
            Chapter(title: "Chapter 5: Negotiation is the fundamental game of human relationships",
                    summary: "Drawing on his training as a theatre actor, Taraban frames all relationship negotiation as 'the Game of Please/No,' in which a wanter tries to turn a giver's default 'no' into a 'yes.' Because wanting is free and giving is costly, the giver's default posture protects scarce resources, giving rise to recognizable 'core strategies' — intimidation, seduction, pity, friendliness, authority, quitting, and others — each of which works by manipulating a specific emotion. He also names two common gendered playbooks: men who become passive 'ferryboat captains,' and women who become 'stowaways' via slow relationship creep.",
                    keyLessons: ["Whoever visibly wants more is at a structural disadvantage — successful wanters strike a 'take it or leave it' balance rather than maximizing effort.", "Twelve core strategies, from intimidation to charm to quitting, all work by evoking a specific emotion in the giver, positive or negative.", "Men who become 'ferryboat captains' — letting the passenger dictate the destination — can never later ask for reciprocity without it feeling like betrayal."],
                    chapterNumber: 5),
            Chapter(title: "Chapter 6: The more powerful player always wins the Game",
                    summary: "Power — the ability to get others to act in service of your goals — is always psychological, never material; money, status, and physical strength are merely 'power proxies' that only work to the extent they excite fear, desire, or awe in someone else. Taraban lays out ten observable principles of power (moving less, being less committed, having more options, willingness to sacrifice and transgress, emotional resilience, invisibility, flexibility, knowledge of the other, and communication skill) and argues women hold more of these attributes on average in heterosexual relationships. Because emotional manipulation only works if the target validates and can't tolerate the emotion being stirred up, emotional resilience is the single best defense any player has.",
                    keyLessons: ["Power proxies like wealth, status, and strength only function through the emotions they excite — resilience to those emotions is functional immunity to manipulation.", "The player with more options, less commitment, and more willingness to walk away structurally wins negotiations over time.", "Rejection is not painful, personal, or permanent — treating it as mere feedback preserves your ability to hear useful information inside a 'no.'"],
                    chapterNumber: 6),
            Chapter(title: "Chapter 7: Attractiveness is the key to power in sexual relationships",
                    summary: "Attractiveness is a 'master key' that unlocks most other principles of power in sexual relationships, operating under three laws: people want what they want (not what wants them); it's impossible for two people to be equally attracted, creating the complementary 'adorer' and 'adored' roles and the attraction gap between them; and all forms of attraction are functionally indistinguishable from attraction to circumstance. That last law explains why exes suddenly seem desirable again once they're gone — it's the shift in the balance of attraction and new catalysts like scarcity and jealousy, not any real change in the person.",
                    keyLessons: ["You can't make someone want you more by wanting them more — cultivate your own attractiveness to the right person instead.", "Someone is always the adorer and someone the adored in every relationship; each role carries real trade-offs between feeling and power.", "Because attraction to circumstances feels identical to attraction to a person, breakup 'reunions' often fade once the original catalysts — distance, uncertainty, jealousy — disappear."],
                    chapterNumber: 7),
            Chapter(title: "Chapter 8: There is no happily ever after",
                    summary: "The maintenance phase of a relationship — the part that gets the least attention in dating advice — brings three recurring crises: the Crisis of Disillusionment (around six months in, when the fantasy projected onto a new partner collapses under real knowledge of them), the Attempted Mutiny (when an invested partner tries to seize control of the relationship's ends or means), and the Doldrums (a slow decline in passion once total security removes sex's bonding function). Each crisis is survivable — by dating inside your real lifestyle instead of a fantasy, calling a mutineer's bluff, and deliberately reintroducing scarcity, mystery, and separation to escape the Doldrums.",
                    keyLessons: ["Attraction is always somewhat distorted at first; a relationship truly begins only once the initial fantasy collapses in the Crisis of Disillusionment.", "Small concessions to a partner's escalating demands — an Attempted Mutiny — train more demands, so hold the line early.", "Security and passion trade off against each other; deliberately reintroducing distance, mystery, and uncertainty is often what revives desire in the Doldrums."],
                    chapterNumber: 8),
            Chapter(title: "Chapter 9: Love has nothing to do with relationships",
                    summary: "Taraban distinguishes non-transactable goods (NTGs) like friendship, loyalty, and love — given freely at the pleasure of the giver and impossible to earn or buy — from relationships, which necessarily involve exchange. Because love expects nothing in return, it is structurally independent of, and often at odds with, the rules, definitions, and compromises that make relationships function. He also argues Western romantic love is transfigured religious devotion originating with the 12th-century Cathars, built on unobtainability, tragedy, and obstruction, which is why romance and lasting partnership tend to pull people in opposite directions.",
                    keyLessons: ["Real love, friendship, and loyalty are given freely and can't be transacted for — that is exactly what makes them non-transactable and unconditional.", "Romantic love historically functioned as displaced religious devotion, which explains why it demands unobtainability, tragedy, and obstruction to stay alive.", "Trying to run a relationship's fair exchange and love's unconditional self-sacrifice at the same time is a major reason 'love marriages' fail."],
                    chapterNumber: 9),
            Chapter(title: "Chapter 10: You can't have any relationship with anyone",
                    summary: "Taraban argues that 90% of relationship success comes down to selection, not effort — a relationship, the specific dynamic between two people, is non-fungible, so most conflict stems from expecting someone to fit a structure they were never suited for. He recommends treating dating like a hiring process: 'hire slow, fire fast,' define a concrete criteria set before searching, keep the expensive word 'and' to a minimum, and finally check two questions before committing long-term — do I like this person, and do I like who I am when I'm with them.",
                    keyLessons: ["Most relationship conflict comes from selection error, not a lack of effort — you can't have just any relationship with anyone.", "Every additional 'and' in your criteria set makes finding a compatible match statistically and economically far more expensive.", "Ask two questions before committing long-term: do I like this person (not just love them), and do I like who I become around them."],
                    chapterNumber: 10),
            Chapter(title: "Chapter 11: There is always a better move",
                    summary: "Because women's normalized SMV peaks around 18 and declines steadily while men's rises from 18 through their 40s and then holds, the optimal strategies for each sex are near-inversions of each other: women's default mode should be to act and secure commitment early, while men's default mode should be to wait, build wealth and status, and avoid committing prematurely. Taraban urges women who want a family to treat their 20s as a real deadline and 'act as their own father,' and urges men to build lasting optionality through visible competence and renown rather than passively waiting for the right woman to appear.",
                    keyLessons: ["Women's SMV peaks young and declines; men's rises through their 30s — this asymmetry is why the two sexes' optimal dating strategies are near-inversions of each other.", "Age 30 is roughly the crossover point where the average man's SMV first exceeds the average woman's, which is why marriages cluster around that age.", "Men build lasting optionality mainly through visible competence and renown ('fishing'), not by waiting passively for the right woman to appear."],
                    chapterNumber: 11),
            Chapter(title: "Chapter 12: People don't really want relationships",
                    summary: "Taraban's closing argument is that people want value, not relationships per se — a relationship is just one (increasingly expensive) strategy for securing that value, so as birth control and Web 2.0 technologies made other paths to sex, resources, and validation cheaper, easier, and safer, both marriage and casual relationships predictably declined. He closes by arguing modern marriage collapses under an impossible hyperconflation of roles — friend, lover, co-parent, business partner, soulmate — it was never designed to hold, and proposes supplementing marriage with a wider range of legitimate relationship structures rather than replacing it.",
                    keyLessons: ["People don't inherently want relationships — they want value, and will abandon relationships the moment cheaper, easier, safer alternatives exist.", "Modern marriage often fails because it has been hyperconflated into too many roles at once — friend, lover, co-parent, business partner, soulmate.", "Society may need to legitimize a wider range of relationship structures rather than force every pairing into one monolithic marital ideal."],
                    chapterNumber: 12)
        ]

        for chapter in chapters {
            chapter.book = book
            book.chapters.append(chapter)
        }

        // --- Highlights / Quotes ---
        let highlights = [
            Highlight(text: "A relationship is the medium in which value is transacted. Where value is transacted, a relationship exists. Conversely, where no value is transacted, no relationship exists.", chapter: "Chapter 1", tags: ["value", "relationships", "economics"], isReminder: true),
            Highlight(text: "People enter into (and remain in) sexual relationships with their perceived best options.", chapter: "Chapter 1", tags: ["attraction", "perception", "dating"], isReminder: true),
            Highlight(text: "To become a captain, you need to complete three challenges. You need to build a boat. You need to learn to sail. And you need to chart a course.", chapter: "Chapter 2", tags: ["captains", "self-mastery", "dating"], isReminder: true),
            Highlight(text: "All relationships – from casual hook-ups to lifelong partnerships – are comprised of three stages: attraction, negotiation, and maintenance.", chapter: "Chapter 2", tags: ["relationships", "stages"], isReminder: false),
            Highlight(text: "Ultimately, since attraction is based on perception, if you believe that someone is \"out of your league,\" you're right.", chapter: "Chapter 3", tags: ["perception", "confidence", "attraction"], isReminder: true),
            Highlight(text: "A man's transacted sexual marketplace value is the median normalized sexual marketplace value of the women from whom he has secured sex.", chapter: "Chapter 3", tags: ["value", "tSMV"], isReminder: false),
            Highlight(text: "Contrary to popular belief, the necessity of negotiating sexual opportunity is not a tragedy. Rather, the tragedy would occur if the negotiation were no longer necessary.", chapter: "Chapter 4", tags: ["negotiation", "self-improvement", "marketplace"], isReminder: true),
            Highlight(text: "Men trade resources for sexual opportunity, and women trade sexual opportunity for resources.", chapter: "Chapter 4", tags: ["economics", "gender", "dating"], isReminder: false),
            Highlight(text: "It costs the wanter nothing to want, but it costs the giver something to give.", chapter: "Chapter 5", tags: ["negotiation", "wanting", "economics"], isReminder: true),
            Highlight(text: "The Game of Please/No is simple. There are always two players. One player – whom we'll call the wanter – can only say the word \"please.\"", chapter: "Chapter 5", tags: ["negotiation", "please-no", "game"], isReminder: false),
            Highlight(text: "Power is not material: it's psychological.", chapter: "Chapter 6", tags: ["power", "psychology"], isReminder: true),
            Highlight(text: "It is technically not possible to be emotionally manipulated by another person. On some level, only you can emotionally manipulate yourself.", chapter: "Chapter 6", tags: ["manipulation", "resilience", "power"], isReminder: true),
            Highlight(text: "People want what they want, not what wants them.", chapter: "Chapter 7", tags: ["attraction", "desire", "dating"], isReminder: true),
            Highlight(text: "It's not possible to know whether you're attracted to the person or to the circumstances surrounding the person.", chapter: "Chapter 7", tags: ["attraction", "misunderstanding"], isReminder: true),
            Highlight(text: "The truth is that there is no happily ever after. When you're out on the open seas, you spend every day staying above water. A ship never gets to not float.", chapter: "Chapter 8", tags: ["maintenance", "relationships", "reality"], isReminder: true),
            Highlight(text: "Without attraction, there can be no desire. If you want to keep the desire alive in your relationship, then you need to protect the upstream sources of desire that feed into that outcome.", chapter: "Chapter 8", tags: ["desire", "doldrums", "passion"], isReminder: true),
            Highlight(text: "Love has nothing to do with relationships.", chapter: "Chapter 9", tags: ["love", "relationships"], isReminder: true),
            Highlight(text: "Love is the humiliated self, triumphant.", chapter: "Chapter 9", tags: ["love", "sacrifice"], isReminder: false),
            Highlight(text: "You can't have any relationship with anyone. You can only have certain relationships with certain people.", chapter: "Chapter 10", tags: ["selection", "compatibility", "dating"], isReminder: true),
            Highlight(text: "People often say that relationships take work. This isn't technically true. It's more accurate to say the amount of work a relationship requires is inversely proportional to the goodness of fit.", chapter: "Chapter 10", tags: ["goodness-of-fit", "selection", "effort"], isReminder: true),
            Highlight(text: "For most of their lives, most men will never be in a more disadvantaged position in the sexual marketplace than they are today.", chapter: "Chapter 11", tags: ["men", "strategy", "marketplace"], isReminder: false),
            Highlight(text: "In most cases, there will never be a better time for a woman to secure the relationship she wants with the man she wants to have it with than today.", chapter: "Chapter 11", tags: ["women", "strategy", "urgency"], isReminder: true),
            Highlight(text: "The only rational conclusion from all this is that what people really want is value – not relationships, per se.", chapter: "Chapter 12", tags: ["value", "relationships", "thesis"], isReminder: true),
            Highlight(text: "This is why marriage fails: we want it to be more than it is, and so we expect our partners to be more than they are.", chapter: "Chapter 12", tags: ["marriage", "expectations"], isReminder: true)
        ]

        for highlight in highlights {
            highlight.book = book
            book.highlights.append(highlight)
        }

        try? modelContext.save()
    }
}
