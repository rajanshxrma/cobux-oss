import SwiftUI
import SwiftData

extension SeedData {
    static func seedAttached(modelContext: ModelContext) {
        // Check if book already exists to avoid duplicates
        let fetchDescriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.title == "Attached" })
        if let existing = try? modelContext.fetch(fetchDescriptor), !existing.isEmpty {
            // Backfill the cover for installs seeded before covers existed, and
            // repair installs seeded with the old OpenLibrary id 8620497 — a real
            // but obscure printing. This is the cover most editions/readers
            // actually recognize.
            if let existingBook = existing.first,
               existingBook.coverImageURL == nil || existingBook.coverImageURL == "https://covers.openlibrary.org/b/id/8620497-L.jpg" {
                existingBook.coverImageURL = "https://i.gr-assets.com/images/S/compressed.photo.goodreads.com/books/1311705552l/9547888.jpg"
                try? modelContext.save()
            }
            return
        }

        let book = Book(
            title: "Attached",
            author: "Amir Levine & Rachel Heller",
            coverColorHex: "#B45309", // Warm dusty rose-amber, distinct from the amber/navy/crimson already in use
            coverImageURL: "https://i.gr-assets.com/images/S/compressed.photo.goodreads.com/books/1311705552l/9547888.jpg"
        )

        modelContext.insert(book)

        // --- Chapters ---
        let chapters = [
            Chapter(title: "1. Decoding Relationship Behavior",
                    summary: "Attachment theory holds that the need for a close bond with a partner is wired into our biology by evolution, not a sign of weakness. Adults fall into one of three attachment styles first identified in infants—secure, anxious, and avoidant—and these styles predict how a couple will communicate, fight, and love long before any 'complex psychological explanation' is needed.",
                    keyLessons: ["Roughly 50% of adults are secure, 20% anxious, 25% avoidant, and 3-5% fall into a rarer disorganized category.", "Attachment style shapes your view of intimacy, conflict, sex, and communication—it is not random personal quirkiness.", "Attachment styles are stable but plastic: about one in four people shift styles over a four-year period, often without realizing it."],
                    chapterNumber: 1),
            Chapter(title: "2. Dependency Is Not a Bad Word",
                    summary: "Western culture treats needing a partner as a character flaw, but biology says otherwise: once two people attach, they become one physiological unit that regulates each other's heart rate, blood pressure, and stress hormones. The 'dependency paradox' shows that the more effectively dependent people are on each other, the more independent and daring they become—so a secure base, not self-sufficiency, is what lets people thrive.",
                    keyLessons: ["Most people are only as needy as their unmet needs; met needs turn attention outward, not inward.", "A partner functions as a biological co-regulator of stress, not just an emotional preference.", "Chasing 'differentiation' and minimizing dependency on a partner works against how attachment actually functions."],
                    chapterNumber: 2),
            Chapter(title: "3. Step One: What Is My Attachment Style?",
                    summary: "The chapter walks the reader through a self-assessment based on the Experience in Close Relationship (ECR) questionnaire, scored along two dimensions: comfort with intimacy (avoidance) and anxiety about a partner's love and availability. Where you land on those two axes—not your personality or charm—determines whether you're secure, anxious, or avoidant.",
                    keyLessons: ["Attachment style is defined by two independent dimensions: intimacy avoidance and relationship anxiety.", "Low avoidance + low anxiety = secure; low avoidance + high anxiety = anxious; high avoidance + low anxiety = avoidant.", "A small percentage of people score high on both dimensions, combining anxious and avoidant traits."],
                    chapterNumber: 3),
            Chapter(title: "4. Step Two: Cracking the Code—What Is My Partner's Style?",
                    summary: "Most people unknowingly reveal their attachment style through everyday words and actions, so this chapter offers a companion questionnaire plus five 'Golden Rules' for reading a partner or date: whether they seek closeness, how sensitive they are to rejection, and—critically—how they react when you communicate your needs directly. A worked set of six real-life vignettes trains the reader to spot each style in the wild.",
                    keyLessons: ["The single most telling test is how someone responds when you express a genuine need—secures accommodate, anxious partners open up, avoidants get defensive or dismissive.", "Don't rely on one behavior in isolation; look for a coherent pattern across many small signals.", "What a partner does *not* say or do can be as revealing as what they do say."],
                    chapterNumber: 4),
            Chapter(title: "5. Living with a Sixth Sense for Danger: The Anxious Attachment Style",
                    summary: "Anxious people have a hypersensitive attachment system that detects the faintest hint of a partner's unavailability, triggering 'activating strategies' and 'protest behavior' aimed at reestablishing closeness. The chapter explains why anxious people are statistically more likely to date avoidants, why an activated attachment system gets mistaken for passion, and lays out a five-step coaching plan—including the 'abundance philosophy'—for finding a secure partner instead.",
                    keyLessons: ["An activated attachment system (obsessing, checking, chasing reassurance) is not the same thing as love or passion.", "Waiting a little longer before reacting turns an anxious person's sensitivity into an accurate read of others rather than a misjudgment.", "Dating several people at once (the abundance philosophy) desensitizes an overactive attachment system and makes it easier to rule out avoidant matches early."],
                    chapterNumber: 5),
            Chapter(title: "6. Keeping Love at Arm's Length: The Avoidant Attachment Style",
                    summary: "Avoidants suppress a genuine, biologically real need for closeness using 'deactivating strategies'—fixating on a partner's flaws, pining for a 'phantom ex,' waiting for 'the one,' and mistaking self-reliance for independence. Experiments show avoidants' bodies register the same attachment-related distress as everyone else, but only when their conscious defenses are distracted; the chapter ends with eight concrete actions avoidants can take to stop pushing love away.",
                    keyLessons: ["Deactivating strategies (nitpicking a partner, idealizing an ex, chasing 'the one') function to suppress closeness, not to reflect the partner's actual shortcomings.", "Self-reliance and independence are not the same thing; over-valuing self-reliance cuts avoidants off from a key source of well-being.", "Avoidants can change, but usually only after consciously identifying their deactivating patterns in the moment they occur."],
                    chapterNumber: 6),
            Chapter(title: "7. Getting Comfortably Close: The Secure Attachment Style",
                    summary: "Secure people are consistently the best predictor of relationship satisfaction—not because of charm or personality, but because their calm attachment system lets them communicate needs directly, forgive easily, and act as a 'secure base' that measurably raises a partner's own security over time. The chapter also warns that secure people are not immune to bad relationships, since their tendency to take responsibility for a partner's well-being can keep them too long in a struggling bond.",
                    keyLessons: ["Secure partners create a 'buffering effect,' raising an anxious or avoidant partner's satisfaction and functioning toward their own high baseline.", "Being available, not interfering, and encouraging a partner's goals are the three concrete behaviors that create a secure base.", "If a normally secure person starts feeling anxious, jealous, or starts withdrawing and playing games, it's a warning sign about the relationship, not a personality change."],
                    chapterNumber: 7),
            Chapter(title: "8. The Anxious-Avoidant Trap",
                    summary: "When an anxious partner's pursuit meets an avoidant partner's retreat, couples fall into a self-reinforcing 'anxious-avoidant trap': a roller-coaster of temporary closeness followed by withdrawal, arguments about trivial things that are really about intimacy, and a dynamic in which conflict resolution itself feels threatening to the avoidant partner. Left unaddressed, the anxious partner typically ends up making all the concessions as the relationship settles into 'stable instability.'",
                    keyLessons: ["Surface arguments (a washing machine, a hotel room, a Facebook friend) are often proxies for a deeper, unspoken clash over how much closeness the couple wants.", "Avoidants often unconsciously resist resolving conflict because resolution itself creates unwanted intimacy.", "Without intervention, intimacy gaps tend to widen rather than shrink as a relationship progresses through bigger life events."],
                    chapterNumber: 8),
            Chapter(title: "9. Escaping the Anxious-Avoidant Trap",
                    summary: "Because attachment styles are 'stable but plastic,' couples caught in the trap can move toward security by identifying an 'integrated secure role model' to emulate and by completing a detailed relationship inventory that maps out what activates or deactivates each partner's attachment system. Two extended case studies—the couple who solved chronic distance anxiety with a scheduled 'thinking of you' text, and the couple who solved suffocation with a rented 'buffer zone' apartment—show the method working in practice.",
                    keyLessons: ["Mentally rehearsing how a known secure person would react to a situation can 'prime' you toward more secure behavior yourself.", "A written relationship inventory—tracking recurring triggers, reactions, and their attachment roots—turns vague recurring fights into solvable, specific problems.", "Small, concrete accommodations (a scheduled text, a private space) can resolve conflicts that sound unsolvable when framed only as personality clashes."],
                    chapterNumber: 9),
            Chapter(title: "10. When Abnormal Becomes the Norm: An Attachment Guide to Breaking Up",
                    summary: "Through Marsha's account of her marriage to the avoidant, belittling Craig, this chapter shows how an anxious-avoidant match can deteriorate until being mistreated becomes the relationship's normal, unquestioned baseline—and explains the biological 'rebound effect' that makes leaving feel like physical pain and pulls people back to exes even after a clean break. Nine concrete strategies help readers recognize when they've become 'the enemy' in their own inner circle and survive the breakup process.",
                    keyLessons: ["Ask whether you're treated like royalty or like the enemy in your own relationship's 'inner circle'—it's a clearer diagnostic than whether you still love your partner.", "Breakup pain activates the same brain regions as physical injury, which is why willpower alone often isn't enough to stay away from an ex.", "Deliberately writing down concrete reasons you left, and asking a trusted friend for a reality check, counteracts the attachment system's tendency to flood you with only the good memories."],
                    chapterNumber: 10),
            Chapter(title: "11. Effective Communication: Getting the Message Across",
                    summary: "Effective communication—stating your needs directly, specifically, and without blame—is the single tool secure people use both to screen out incompatible partners early and to keep existing relationships healthy, because a partner's real-time response to a clearly stated need reveals more than months of guesswork. The chapter gives five concrete principles (wear your heart on your sleeve, focus on needs, be specific, don't blame, be assertive and unapologetic) and shows why anxious people default to protest behavior and avoidant people default to silence instead.",
                    keyLessons: ["A partner's response to a direct, non-accusatory statement of your needs is far more diagnostic than anything they volunteer unprompted.", "Framing statements around 'I need,' 'I feel,' and 'I want' keeps communication effective instead of accusatory.", "It is never too late to start using effective communication, even mid-argument or years into a relationship."],
                    chapterNumber: 11),
            Chapter(title: "12. Working Things Out: Five Secure Principles for Dealing with Conflict",
                    summary: "Good relationships aren't defined by how little couples fight but by how they fight: secure people instinctively show concern for their partner's well-being, stay focused on the actual problem, avoid generalizing a single incident into a character attack, stay emotionally engaged rather than withdrawing, and communicate feelings effectively. A workshop of real vignettes—including couples where both partners are secure but still bicker for decades—shows these principles are learnable skills, not fixed personality traits.",
                    keyLessons: ["Relationship satisfaction depends on how couples disagree and what they disagree about, not on how often they disagree.", "The five secure conflict principles—concern for the other's well-being, staying on-topic, not generalizing, staying engaged, and communicating clearly—are learnable regardless of your starting attachment style.", "Assuming the best about a partner's intentions during conflict tends to become self-fulfilling, just as assuming the worst does."],
                    chapterNumber: 12)
        ]

        for chapter in chapters {
            chapter.book = book
            book.chapters.append(chapter)
        }

        // --- Highlights / Quotes ---
        let highlights = [
            Highlight(text: "If you want to take the road to independence and happiness, first find the right person to depend on and travel down it with them.", chapter: "2. Dependency Is Not a Bad Word", tags: ["dependency", "independence", "secure base"], isReminder: true),
            Highlight(text: "The more effectively dependent people are on one another, the more independent and daring they become.", chapter: "2. Dependency Is Not a Bad Word", tags: ["dependency paradox", "growth"], isReminder: true),
            Highlight(text: "All people in our society, whether they have just started dating someone or have been married for forty years, fall into one of these categories, or, more rarely, into a combination of the latter two (anxious and avoidant).", chapter: "1. Decoding Relationship Behavior", tags: ["attachment styles", "framework"], isReminder: false),
            Highlight(text: "When you finally talk to your partner, you often do it in a way that is explosive, accusatory, critical, or threatening.", chapter: "5. Living with a Sixth Sense for Danger: The Anxious Attachment Style", tags: ["anxious", "communication"], isReminder: false),
            Highlight(text: "Remember, an activated attachment system is not passionate love.", chapter: "5. Living with a Sixth Sense for Danger: The Anxious Attachment Style", tags: ["anxious", "love versus anxiety"], isReminder: true),
            Highlight(text: "Happiness only real when shared.", chapter: "6. Keeping Love at Arm's Length: The Avoidant Attachment Style", tags: ["avoidant", "connection"], isReminder: true),
            Highlight(text: "Many avoidants confuse self-reliance with independence.", chapter: "6. Keeping Love at Arm's Length: The Avoidant Attachment Style", tags: ["avoidant", "self-reliance"], isReminder: true),
            Highlight(text: "So not only do people with a secure attachment style fare better in relationships, they also create a buffering effect, somehow managing to raise their insecure partner's relationship satisfaction and functioning to their own high level.", chapter: "7. Getting Comfortably Close: The Secure Attachment Style", tags: ["secure", "buffering effect"], isReminder: true),
            Highlight(text: "Thus the closer the anxious tries to get, the more distant the avoidant acts.", chapter: "8. The Anxious-Avoidant Trap", tags: ["anxious-avoidant trap", "dynamics"], isReminder: true),
            Highlight(text: "Now you have to plead just to return to your initial, unsatisfactory status quo (and often have to compromise for less).", chapter: "8. The Anxious-Avoidant Trap", tags: ["anxious-avoidant trap", "conflict"], isReminder: false),
            Highlight(text: "Attachment styles are stable but plastic.", chapter: "9. Escaping the Anxious-Avoidant Trap", tags: ["change", "attachment styles"], isReminder: true),
            Highlight(text: "Your only crime has been to become too close to someone who can't tolerate it.", chapter: "10. When Abnormal Becomes the Norm: An Attachment Guide to Breaking Up", tags: ["breakup", "self-blame"], isReminder: true),
            Highlight(text: "Studies have found that the same areas in the brain that light up in imaging scans when we break a leg are activated when we split up with our mate.", chapter: "10. When Abnormal Becomes the Norm: An Attachment Guide to Breaking Up", tags: ["breakup", "neuroscience"], isReminder: false),
            Highlight(text: "Expressing your needs and expectations to your partner in a direct, nonaccusatory manner is an incredibly powerful tool.", chapter: "11. Effective Communication: Getting the Message Across", tags: ["communication", "needs"], isReminder: true),
            Highlight(text: "Your relationship needs are valid--period.", chapter: "11. Effective Communication: Getting the Message Across", tags: ["communication", "self-worth"], isReminder: true),
            Highlight(text: "What does differentiate between couples and affect their satisfaction levels in their relationships is not how much they disagree, but how they disagree and what they disagree about.", chapter: "12. Working Things Out: Five Secure Principles for Dealing with Conflict", tags: ["conflict", "secure"], isReminder: true),
            Highlight(text: "It's always more effective to assume the best in conflict situations.", chapter: "12. Working Things Out: Five Secure Principles for Dealing with Conflict", tags: ["conflict", "mindset"], isReminder: true)
        ]

        for highlight in highlights {
            highlight.book = book
            book.highlights.append(highlight)
        }

        try? modelContext.save()
    }
}
