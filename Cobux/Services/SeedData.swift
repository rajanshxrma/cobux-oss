import SwiftUI
import SwiftData

struct SeedData {
    static func seed12Rules(modelContext: ModelContext) {
        // Check if book already exists to avoid duplicates
        let fetchDescriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.title == "12 Rules for Life" })
        if let existing = try? modelContext.fetch(fetchDescriptor), !existing.isEmpty {
            // Backfill the cover for installs seeded before covers existed.
            if let existingBook = existing.first, existingBook.coverImageURL == nil {
                existingBook.coverImageURL = "https://covers.openlibrary.org/b/id/8131760-L.jpg"
                try? modelContext.save()
            }
            return
        }
        
        let book = Book(
            title: "12 Rules for Life",
            author: "Jordan B. Peterson",
            coverColorHex: "#D97706", // A nice amber/gold for this book
            coverImageURL: "https://covers.openlibrary.org/b/id/8131760-L.jpg"
        )
        
        modelContext.insert(book)
        
        // --- Chapters (The 12 Rules) ---
        let chapters = [
            Chapter(title: "Rule 1: Stand up straight with your shoulders back",
                    summary: "Embrace the hierarchy of competence and face the world with courage. Posture affects serotonin levels, which in turn affects confidence and how others treat you.",
                    keyLessons: ["Face the demands of life voluntarily.", "Physical posture influences your neurological state.", "Accept the terrible responsibility of life."],
                    chapterNumber: 1),
            Chapter(title: "Rule 2: Treat yourself like someone you are responsible for helping",
                    summary: "People are often better at caring for their pets than themselves. You must recognize your own inherent value and take care of your physical and mental health.",
                    keyLessons: ["Don't despise yourself.", "Determine what is truly good for you, not just what you want.", "Articulate your own principles and follow them."],
                    chapterNumber: 2),
            Chapter(title: "Rule 3: Make friends with people who want the best for you",
                    summary: "Surround yourself with people who support your upward aim. It is not selfish to distance yourself from people who drag you down.",
                    keyLessons: ["You are not obligated to support someone who makes the world a worse place.", "Good friends will not tolerate your cynicism or destructiveness.", "Surround yourself with people who celebrate your successes."],
                    chapterNumber: 3),
            Chapter(title: "Rule 4: Compare yourself to who you were yesterday, not to who someone else is today",
                    summary: "There will always be someone better than you at something. Focus on your own incremental progress instead of becoming resentful of others' success.",
                    keyLessons: ["Aim small and improve daily.", "Pay attention to what you can actually fix.", "Your trajectory is more important than your current position."],
                    chapterNumber: 4),
            Chapter(title: "Rule 5: Do not let your children do anything that makes you dislike them",
                    summary: "Parents must act as proxies for the real world, socializing their children so they are acceptable to society. If you don't discipline them, the world will do it much more harshly.",
                    keyLessons: ["Discipline is an act of love.", "Rules must be clear and enforced consistently.", "Don't outsource your parental responsibilities."],
                    chapterNumber: 5),
            Chapter(title: "Rule 6: Set your house in perfect order before you criticize the world",
                    summary: "Before attempting to fix complex societal issues, take responsibility for your own life, your own room, and your own family.",
                    keyLessons: ["Stop doing what you know to be wrong.", "Clean up your own immediate environment first.", "Resentment and arrogance are the enemies of order."],
                    chapterNumber: 6),
            Chapter(title: "Rule 7: Pursue what is meaningful (not what is expedient)",
                    summary: "Expedience is following blind impulse; meaning is the regulation of impulse. Meaning is found in taking on responsibility and making sacrifices for the future.",
                    keyLessons: ["Sacrifice delay gratification.", "Meaning emerges when impulses are regulated and organized.", "Do what is right, not what is easy."],
                    chapterNumber: 7),
            Chapter(title: "Rule 8: Tell the truth – or, at least, don't lie",
                    summary: "Lies warp the structure of reality. If you betray yourself by saying what you don't believe, you will become weak and corrupt.",
                    keyLessons: ["Truth builds an unshakeable foundation.", "Lies always grow and require more lies.", "Speak your truth and face the consequences."],
                    chapterNumber: 8),
            Chapter(title: "Rule 9: Assume that the person you are listening to might know something you don't",
                    summary: "True listening requires humility. You must be willing to let your current understanding die in order to learn something new.",
                    keyLessons: ["Listen without trying to win the argument.", "Summarize what the other person said to ensure you understand.", "Wisdom is an ongoing process, not a final state."],
                    chapterNumber: 9),
            Chapter(title: "Rule 10: Be precise in your speech",
                    summary: "When things break down, you must precisely identify the problem. Vague fears are terrifying; articulated problems can be solved.",
                    keyLessons: ["Give the monster a name.", "Specify exactly what is wrong so you can fix it.", "Don't hide behind ambiguity."],
                    chapterNumber: 10),
            Chapter(title: "Rule 11: Do not bother children when they are skateboarding",
                    summary: "Competence and resilience are built through encountering danger and mastering it. Don't overprotect people to the point of making them weak.",
                    keyLessons: ["Risk is necessary for development.", "Let people confront the unknown.", "Encourage strength rather than creating safe spaces."],
                    chapterNumber: 11),
            Chapter(title: "Rule 12: Pet a cat when you encounter one on the street",
                    summary: "Life is full of suffering and tragedy. You must find ways to appreciate the small moments of grace and beauty to sustain yourself through the darkness.",
                    keyLessons: ["Notice the small, good things.", "Take a break from the tragedy of Being.", "Balance suffering with gratitude."],
                    chapterNumber: 12)
        ]
        
        for chapter in chapters {
            chapter.book = book
            book.chapters.append(chapter)
        }
        
        // --- Highlights / Quotes ---
        let highlights = [
            Highlight(text: "To stand up straight with your shoulders back is to accept the terrible responsibility of life, with eyes wide open.", chapter: "Rule 1", tags: ["responsibility", "posture", "courage"], isReminder: true),
            Highlight(text: "If you fulfill your obligations everyday you don't need to worry about the future.", chapter: "Rule 2", tags: ["duty", "future"], isReminder: true),
            Highlight(text: "You are not everything you could be, and you know it.", chapter: "Rule 4", tags: ["potential", "growth"], isReminder: true),
            Highlight(text: "Compare yourself to who you were yesterday, not to who someone else is today.", chapter: "Rule 4", tags: ["comparison", "progress"], isReminder: true),
            Highlight(text: "You can only find out what you actually believe (rather than what you think you believe) by watching how you act.", chapter: "Rule 7", tags: ["belief", "action", "truth"], isReminder: true),
            Highlight(text: "Meaning is the ultimate balance between, on the one hand, the chaos of transformation and possibility and on the other, the discipline of pristine order.", chapter: "Rule 7", tags: ["meaning", "chaos", "order"], isReminder: true),
            Highlight(text: "If you will not reveal yourself to others, you cannot reveal yourself to yourself.", chapter: "Rule 8", tags: ["truth", "honesty", "self-knowledge"], isReminder: true),
            Highlight(text: "Assume that the person you are listening to might know something you don't.", chapter: "Rule 9", tags: ["listening", "humility"], isReminder: true),
            Highlight(text: "Intolerance of others' views (no matter how ignorant or incoherent they may be) is not simply wrong; in a world where there is no right or wrong, it is worse: it is a sign you are embarrassingly unsophisticated or, possibly, dangerous.", chapter: "Rule 9", tags: ["intolerance", "perspective"], isReminder: false),
            Highlight(text: "When you have something to say, silence is a lie.", chapter: "Rule 8", tags: ["truth", "speech"], isReminder: true),
            Highlight(text: "Don't underestimate the power of vision and direction. These are irresistible forces, able to transform what might appear to be unconquerable obstacles into traversable pathways and expanding opportunities.", chapter: "Rule 4", tags: ["vision", "direction", "obstacles"], isReminder: true),
            Highlight(text: "Set your house in perfect order before you criticize the world.", chapter: "Rule 6", tags: ["responsibility", "order", "criticism"], isReminder: true)
        ]
        
        for highlight in highlights {
            highlight.book = book
            book.highlights.append(highlight)
        }

        try? modelContext.save()
    }

    static func seedBeyondOrder(modelContext: ModelContext) {
        // Check if book already exists to avoid duplicates
        let fetchDescriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.title == "Beyond Order" })
        if let existing = try? modelContext.fetch(fetchDescriptor), !existing.isEmpty {
            // Backfill the cover for installs seeded before covers existed, and
            // repair installs seeded with cover 10517194 — that id is the square
            // audiobook cover, which crops badly into the app's portrait 3:4
            // book-cover frame. 10523751 is the correct portrait hardcover jacket.
            if let existingBook = existing.first,
               existingBook.coverImageURL == nil || existingBook.coverImageURL == "https://covers.openlibrary.org/b/id/10517194-L.jpg" {
                existingBook.coverImageURL = "https://covers.openlibrary.org/b/id/10523751-L.jpg"
                try? modelContext.save()
            }
            return
        }

        let book = Book(
            title: "Beyond Order",
            author: "Jordan B. Peterson",
            coverColorHex: "#1E3A8A", // Deep navy, distinct from 12 Rules' amber
            coverImageURL: "https://covers.openlibrary.org/b/id/10523751-L.jpg" // Portrait hardcover jacket, not the square audiobook cover
        )

        modelContext.insert(book)

        // --- Chapters (The 12 More Rules) ---
        let chapters = [
            Chapter(title: "Rule I: Do not carelessly denigrate social institutions or creative achievement",
                    summary: "Society stays healthy through a living tension between tradition and change. Institutions preserve the hard-won wisdom of the past, while creative rebels renew them when they falter — respect both sides of that balance.",
                    keyLessons: ["Institutions carry accumulated wisdom; treat them with gratitude before criticizing.", "Creativity keeps institutions from ossifying — both conservatives and rebels are necessary.", "Bear the paradox: respect the walls that keep you safe while letting in what is new."],
                    chapterNumber: 1),
            Chapter(title: "Rule II: Imagine who you could be, and then aim single-mindedly at that",
                    summary: "You need a target — the best version of yourself you can currently conceive. Aim at it with discipline, and let the target itself refine as you improve; the aim matters more than the current position.",
                    keyLessons: ["Pick the highest value you can conceive of and aim at it.", "The target moves and recedes as you grow — that is progress, not failure.", "Discipline and transformation together make you the hero of your own story."],
                    chapterNumber: 2),
            Chapter(title: "Rule III: Do not hide unwanted things in the fog",
                    summary: "Avoided problems do not disappear — they accumulate in the fog and breed resentment and corruption. Naming what is wrong, however painful, is the only route back to a life worth living.",
                    keyLessons: ["Small ignored irritations compound into life-poisoning resentment.", "Voluntarily confronting a terrible truth beats living with the falsehood that replaces it.", "Ask, seek, knock — clarity requires truly wanting the answer."],
                    chapterNumber: 3),
            Chapter(title: "Rule IV: Notice that opportunity lurks where responsibility has been abdicated",
                    summary: "Meaning is found in voluntarily picked-up responsibility, not in ease. Where others have dropped the load is exactly where your opportunity — and your destiny — waits.",
                    keyLessons: ["What calls you to your destiny is struggle, not comfort.", "Adopting abandoned responsibility gives life deep, orienting meaning.", "The adventure will frustrate and unsettle you — and it is still where the worthwhile life is found."],
                    chapterNumber: 4),
            Chapter(title: "Rule V: Do not do what you hate",
                    summary: "Distinguish honest lowly work from genuine betrayal of soul. Performing pointless or unjust work, lying about it, and silencing your conscience corrupts you and the world around you.",
                    keyLessons: ["Irritation at low status is not the same as the call of conscience.", "Refusing to say and do what you know to be wrong protects your future self.", "Conscience disturbed daily paves the personal road to hell."],
                    chapterNumber: 5),
            Chapter(title: "Rule VI: Abandon ideology",
                    summary: "Ideologies compress the world's complexity into a single resentful axiom and substitute activism for accomplishment. Address small, precisely defined problems you can personally own instead.",
                    keyLessons: ["Ideological single-cause explanations are too low-resolution to be useful.", "Blaming others is the lazy substitute for solving something concrete.", "Have some humility: straighten out your own life first, then dare a bigger problem."],
                    chapterNumber: 6),
            Chapter(title: "Rule VII: Work as hard as you possibly can on at least one thing and see what happens",
                    summary: "Committed, sacrificial focus on one thing unifies the clamoring multitude inside you into a disciplined personality — and that discipline becomes the thing that can then create and transform.",
                    keyLessons: ["Commitment forges character; aimlessness dissipates it.", "Sacrifice and concentration turn you into one thing instead of many.", "Discipline properly developed becomes creative power, not constraint."],
                    chapterNumber: 7),
            Chapter(title: "Rule VIII: Try to make one room in your home as beautiful as possible",
                    summary: "Beauty reconnects you with the childlike wonder cynicism took away. Making one room beautiful is a practical act of care that establishes a relationship with the highest values.",
                    keyLessons: ["Beauty straightens your aim by reminding you of greater value.", "Creating beauty in your own space is a discipline, not a luxury.", "One genuinely beautiful room is a foothold against chaos and cynicism."],
                    chapterNumber: 8),
            Chapter(title: "Rule IX: If old memories still upset you, write them down carefully and completely",
                    summary: "Persistent painful memories signal that your map of the world is incomplete. Writing them down fully — building a causal understanding of what happened and why — is what frees you from the past.",
                    keyLessons: ["Emotional expression alone does not heal; understanding does.", "Ask what made you vulnerable and what must change in your map of the world.", "We are our assumptions — updating them is painful and liberating."],
                    chapterNumber: 9),
            Chapter(title: "Rule X: Plan and work diligently to maintain the romance in your relationship",
                    summary: "Lasting romance is negotiated and practiced, never automatic. Honest communication, deliberate time together, and commitment desperate enough to force real negotiation keep love alive.",
                    keyLessons: ["Arrange dates and practice them — romance requires scheduling, not spontaneity.", "Let your partner know what you actually want and need.", "Vows create the desperation that makes honest negotiation possible."],
                    chapterNumber: 10),
            Chapter(title: "Rule XI: Do not allow yourself to become resentful, deceitful, or arrogant",
                    summary: "Everyone has reasons for bitterness — life guarantees suffering and betrayal. But resentment, deceit, and arrogance constitute the descent into evil; courage, truth, and gratitude are the way to resist it.",
                    keyLessons: ["Resentment, deceit, and arrogance are the triad that constitutes evil.", "Understanding your own temptation by darkness is the protection against it.", "Faith that you can contend with existence beats bitterness that warps it."],
                    chapterNumber: 11),
            Chapter(title: "Rule XII: Be grateful in spite of your suffering",
                    summary: "Gratitude is not naivety — it is courage in the face of life's darkness. Loving people because of their limitations, not despite them, is part of the antidote to the abyss.",
                    keyLessons: ["Gratitude is an act of courage, chosen with eyes open to suffering.", "People's particularities and fragilities are part of what you come to love.", "Trust and love grounded in reality are the antidote to the darkness."],
                    chapterNumber: 12)
        ]

        for chapter in chapters {
            chapter.book = book
            book.chapters.append(chapter)
        }

        // --- Highlights / Quotes ---
        let highlights = [
            Highlight(text: "Every rule was once a creative act, breaking other rules. Every creative act, genuine in its creativity, is likely to transform itself, with time, into a useful rule.", chapter: "Rule I", tags: ["tradition", "creativity", "institutions"], isReminder: true),
            Highlight(text: "You will pursue a target that is both moving and receding: moving, because you do not have the wisdom to aim in the proper direction when you first take aim; receding, because no matter how close you come to perfecting what you are currently practicing, new vistas of possible perfection will open up in front of you.", chapter: "Rule II", tags: ["aim", "growth", "discipline"], isReminder: true),
            Highlight(text: "If you truly wanted, perhaps you would receive, if you asked. If you truly sought, perhaps you would find what you seek. If you knocked, truly wanting to enter, perhaps the door would open.", chapter: "Rule III", tags: ["truth", "courage", "clarity"], isReminder: true),
            Highlight(text: "What calls you out into the world, however—to your destiny—is not ease. It is struggle and strife.", chapter: "Rule IV", tags: ["responsibility", "destiny", "struggle"], isReminder: true),
            Highlight(text: "And there is no doubt that the road to hell, personally and socially, is paved not so much with good intentions as with the adoption of attitudes and undertaking of actions that inescapably disturb your conscience.", chapter: "Rule V", tags: ["conscience", "integrity"], isReminder: true),
            Highlight(text: "Have some humility. Clean up your bedroom. Take care of your family. Follow your conscience. Straighten up your life. Find something productive and interesting to do and commit to it.", chapter: "Rule VI", tags: ["humility", "responsibility", "action"], isReminder: true),
            Highlight(text: "If you work as hard as you can on one thing, you will change. You will start to also become one thing, instead of the clamoring multitude you once were.", chapter: "Rule VII", tags: ["work", "focus", "character"], isReminder: true),
            Highlight(text: "Beauty leads you back to what you have lost. Beauty reminds you of what remains forever immune to cynicism.", chapter: "Rule VIII", tags: ["beauty", "meaning"], isReminder: true),
            Highlight(text: "To some great degree, we are our assumptions. They structure the world for us.", chapter: "Rule IX", tags: ["assumptions", "memory", "understanding"], isReminder: true),
            Highlight(text: "Do not be naive, and do not expect the beauty of love to maintain itself without all-out effort on your part.", chapter: "Rule X", tags: ["love", "effort", "relationships"], isReminder: true),
            Highlight(text: "You have your reasons for being resentful, deceitful, and arrogant. You face, or will face, terrible, chaotic forces, and you will sometimes be outmatched.", chapter: "Rule XI", tags: ["resentment", "evil", "resistance"], isReminder: true),
            Highlight(text: "So, you might love people despite their limitations, but you also love them because of their limitations.", chapter: "Rule XII", tags: ["gratitude", "love", "acceptance"], isReminder: true)
        ]

        for highlight in highlights {
            highlight.book = book
            book.highlights.append(highlight)
        }

        try? modelContext.save()
    }
}
