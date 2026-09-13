import SwiftUI

/// First run. Four pages: the mark, the three pillars, who this is for, the
/// key. Rewritten for 3.0 -- the previous copy still described the 1.0
/// product ("Store Wisdom / Ask Questions / Get Reminded", "an AI that only
/// knows what you've read", "daily push notifications") on a screen that a
/// potential investor has now seen. Every sentence below names something
/// the app does today, in the app's own words, and nothing it does not:
/// Cobux has no push pipeline (reminders are local, off by default), and
/// chat draws on the library AND, when allowed, the journal.
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage(UserPersona.storageKey) private var personaRaw = UserPersona.retention.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var apiKey = ""
    @State private var currentTab = 0
    @State private var showingKeychainFailureAlert = false
    private var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        TabView(selection: $currentTab) {
            // Page 1: the mark. The identity, not an emoji -- the icon's quote
            // in violet light on black, and one honest line.
            OnboardingPageScroll { _ in
                VStack(spacing: 28) {
                    OnboardingMark()
                    VStack(spacing: 10) {
                        Text("Cobux")
                            .font(.system(size: 40, weight: .bold))
                            .kerning(1.5)
                            .foregroundStyle(.white)
                        Text("Your library, your journal, and a conversation between them.")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .padding()
            }
            .tag(0)

            // Page 2: the three pillars, each in its own hue, then chat --
            // the surface that runs through all of them.
            OnboardingPageScroll { _ in
                VStack(spacing: 28) {
                    Text("What's here")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 22) {
                        FeatureRow(icon: "sparkles", tint: Color.cobuxAccent, title: "Flow",
                                   desc: "Your library, one highlight at a time. Swipe through it, go deeper on any line, or take one straight into a conversation.")
                        FeatureRow(icon: "square.and.pencil", tint: Color.cobuxAccent, title: "Journal",
                                   desc: "Write here, or bring in what you've already written. Keep a passage and Cobux brings it back later; answer an old entry and the journal becomes a correspondence with yourself.")
                        FeatureRow(icon: "clock.arrow.circlepath", tint: Color.cobuxEbb, title: "Ebb",
                                   desc: "Walk backward through your own writing, a card at a time — and meet the line from your library that sits closest to what you wrote.")
                    }
                    .padding()
                    .cobuxCard()

                    Text("Chat runs through all of it. Ask about a book or about your own journal, and Cobux answers from what's actually there — it can look at a photo you attach, too.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    // The five ways in that live OUTSIDE the app, none of which
                    // this page named before -- so the Share Extension, the
                    // Messages panel, three of the four Siri phrases, the Quick
                    // Check widget and the entire Watch app could be learned
                    // only by opening the iOS widget gallery, the Messages
                    // drawer or the Shortcuts app and finding them by accident.
                    //
                    // His standing principle, which settles this: *"user shuold
                    // be shown the features cobux offers and put them in fornt
                    // of users eyes against them manually finding them out
                    // wherever and feel they missed out for even a tiny bit of
                    // time."* Onboarding is the one surface every new user
                    // reads exactly once, which makes it the only place this
                    // can be said without ever becoming a nag.
                    //
                    // One line each, not a second pitch: these are addresses,
                    // not pillars. Nothing here is promised that the bundled
                    // targets do not actually do.
                    VStack(alignment: .leading, spacing: 14) {
                        Text("And where you already are")
                            .font(.headline)
                            .foregroundStyle(.white)
                        WayInRow("square.grid.2x2.fill", "Home Screen widgets — a line from your library, a card to answer, or the journal one tap away.")
                        WayInRow("message.fill", "Messages — tap + in any conversation and choose Cobux to save a line to your journal.")
                        WayInRow("square.and.arrow.up", "Share sheet — reading in Kindle, Books or Safari? Select the text, then Share → Cobux.")
                        WayInRow("waveform", "Siri — “Journal in Cobux.” “Ask Cobux a question.” “Give me a highlight from Cobux.”")
                        WayInRow("applewatch", "Apple Watch — your streak, what's due, and one line to carry. Add Cobux from the Watch app on your phone.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .cobuxCard()
                }
                .padding()
            }
            .tag(1)

            // Page 3: Persona — tunes copy/recommendation framing app-wide.
            // Default is `retention`; every choice keeps the full feature set.
            OnboardingPageScroll { _ in
                VStack(spacing: 24) {
                    Text("What brings you here?")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    VStack(spacing: 12) {
                        ForEach(UserPersona.allCases) { persona in
                            Button {
                                personaRaw = persona.rawValue
                                // Reduce Motion: the page changes, it does not slide.
                                withAnimation(reduceMotion ? nil : .default) { currentTab = 3 }
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: persona.icon)
                                        .font(.title2)
                                        .foregroundStyle(Color.cobuxAccent)
                                        // `.title2` scales with Dynamic Type,
                                        // including accessibility sizes -- a
                                        // fixed `width: 36` clipped the glyph
                                        // at larger text sizes instead of
                                        // just keeping normal-size alignment.
                                        .frame(minWidth: 36)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(persona.title)
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                        Text(persona.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.7))
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer()
                                    // A radio mark for the current choice -- a
                                    // selection, not a completed task, so not
                                    // a tick.
                                    Image(systemName: personaRaw == persona.rawValue ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(personaRaw == persona.rawValue ? Color.cobuxAccent : .white.opacity(0.35))
                                }
                                .padding(14)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: CobuxRadius.card))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("You can change this anytime in Settings.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding()
            }
            .tag(2)

            // Page 4: the key. Honest about what needs it and what does not.
            OnboardingPageScroll { _ in
                VStack(spacing: 24) {
                    Text("One key for Chat")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Text("Chat, voice and quiz writing run on Claude, using your own Anthropic API key. It's stored in this phone's keychain and sent only to Anthropic. Flow, your journal, Ebb and the library work without one.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))

                    SecureField("Anthropic API Key (sk-...)", text: $apiKey)
                        .padding()
                        .cobuxCard()

                    Button(action: {
                        // Trimmed, matching `SettingsView`'s own "Save" -- the one other
                        // place this same key can be entered. A key pasted with a
                        // trailing space/newline (common copying out of an email or
                        // doc) used to get stored as-is here, unlike Settings, which
                        // would silently fail every chat call later with no hint that
                        // whitespace, not the key itself, was the problem.
                        // Unlike `SettingsView`'s "Save" (the one other place this
                        // exact key can be entered), a failed save here used to be
                        // discarded (`_ = KeychainManager.save(...)`) and onboarding
                        // completed anyway -- the user would never see an error, just
                        // every later chat call silently failing with "API Key
                        // Required" and no explanation of why a key they definitely
                        // entered wasn't there. Now: a real save failure blocks
                        // completing onboarding and says so, matching Settings'
                        // honesty about this exact failure mode.
                        if trimmedAPIKey.isEmpty {
                            hasCompletedOnboarding = true
                        } else if KeychainManager.save(key: KeychainManager.anthropicAPIKey, data: trimmedAPIKey) {
                            hasCompletedOnboarding = true
                        } else {
                            showingKeychainFailureAlert = true
                        }
                    }) {
                        // The primary pill, through the token: its type is white
                        // or the dark ink by measured contrast, never hardcoded
                        // white on a tint that cannot carry it (the dark-mode
                        // accent measured 3.2:1 under white).
                        Text(trimmedAPIKey.isEmpty ? "Skip for now" : "Continue")
                            .frame(maxWidth: .infinity)
                            .cobuxPrimaryPill(tint: trimmedAPIKey.isEmpty ? Color.white.opacity(0.14) : Color.cobuxAccent)
                    }
                    .buttonStyle(.plain)

                    Text("Add or change it any time under More → Settings.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding()
            }
            .tag(3)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(
            // The 3.0 identity ground -- the icon's field and the Flow button's
            // capsule -- rather than voice mode's indigo wash. Same token the
            // Flow button paints, so the first screen and the button he will
            // press next are visibly one thing.
            LinearGradient(colors: CobuxColor.identityGradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        // Always dark, regardless of the system colour scheme. This screen
        // (unlike voice mode) can't inherit a dark override from anywhere
        // else: it's the very first thing a fresh install shows, before
        // `themeRaw` in CobuxApp has any value other than its `.system`
        // default. On a phone in Light Mode -- exactly Gulab's first launch
        // -- every unstyled `Text` here used to render near-black on this
        // near-black gradient: real, close-to-unreadable contrast on a
        // brand-new tester's very first screen.
        .preferredColorScheme(.dark)
        .alert("Couldn't Save Key", isPresented: $showingKeychainFailureAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your API key couldn't be saved. You can try again, or tap \"Skip for now\" and add it later in Settings.")
        }
    }
}

/// The app's mark, drawn: the icon's opening quote in violet light on the
/// identity ground. Drawn rather than loaded from the icon set so it cannot
/// go stale against the asset and needs no runtime lookup.
private struct OnboardingMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: CobuxRadius.glassCard, style: .continuous)
            .fill(LinearGradient(colors: CobuxColor.identityGradient, startPoint: .top, endPoint: .bottom))
            .frame(width: 104, height: 104)
            .overlay {
                Image(systemName: "quote.opening")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(Color.cobuxAccent)
                    .shadow(color: Color.cobuxAccent.opacity(0.65), radius: 14)
            }
            .overlay {
                RoundedRectangle(cornerRadius: CobuxRadius.glassCard, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: Color.cobuxAccent.opacity(0.35), radius: 24, y: 10)
            .accessibilityHidden(true)
    }
}

/// Wraps a single page's content in a `ScrollView` sized to at least fill the
/// page (via `GeometryReader`), instead of a bare `VStack`. `TabView(.page)`
/// never scrolls a page on its own -- content that doesn't fit just clips
/// silently at the bottom of the screen. On a small phone (iPhone SE-class)
/// with a larger Dynamic Type accessibility size, page 3's three persona rows
/// or page 4's description + field + button can genuinely exceed the screen
/// height, which used to mean the "Continue"/"Skip for now" button -- the only
/// way page 4 completes onboarding -- became unreachable. `minHeight:
/// proxy.size.height` keeps every page centered exactly as before whenever
/// content fits, and makes it scrollable instead of clipped whenever it
/// doesn't. The content closure receives the page size so a fixed-height
/// element (the widget mock in `WidgetInviteView`) can shrink to fit it.
struct OnboardingPageScroll<Content: View>: View {
    @ViewBuilder var content: (CGSize) -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content(proxy.size)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
    }
}

/// One address, one line. Deliberately lighter than `FeatureRow` -- a `.title`
/// glyph and a headline for each of these would make five entry points read as
/// five more pillars, which they are not.
private struct WayInRow: View {
    let icon: String
    let text: String

    init(_ icon: String, _ text: String) {
        self.icon = icon
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.cobuxAccent)
                // A floor, not a fixed width -- the same Dynamic-Type
                // clipping fix every glyph column on this screen carries.
                .frame(minWidth: 22, alignment: .leading)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    var tint: Color = Color.cobuxAccent
    let title: String
    let desc: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(tint)
                // Same Dynamic-Type-clipping fix as the persona icon above --
                // `.title` grows at accessibility text sizes, so the frame
                // needs a floor, not a fixed width.
                .frame(minWidth: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
