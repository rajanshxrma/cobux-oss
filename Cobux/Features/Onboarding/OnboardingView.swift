import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage(UserPersona.storageKey) private var personaRaw = UserPersona.retention.rawValue
    @State private var apiKey = ""
    @State private var currentTab = 0
    @State private var showingKeychainFailureAlert = false
    private var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        TabView(selection: $currentTab) {
            // Page 1: Welcome
            OnboardingPageScroll {
                VStack(spacing: 24) {
                    Text("📚")
                        .font(.system(size: 100))
                    Text("Welcome to Cobux")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Your books, always with you.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .tag(0)

            // Page 2: Features
            OnboardingPageScroll {
                VStack(spacing: 32) {
                    Text("Features")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    VStack(alignment: .leading, spacing: 24) {
                        FeatureRow(icon: "books.vertical.fill", title: "Store Wisdom", desc: "Save highlights and summaries from your favorite books.")
                        FeatureRow(icon: "message.fill", title: "Ask Questions", desc: "Chat with an AI that only knows what you've read.")
                        FeatureRow(icon: "bell.fill", title: "Get Reminded", desc: "Daily push notifications with quotes to keep you focused.")
                    }
                    .padding()
                    .cobuxCard()
                }
                .padding()
            }
            .tag(1)

            // Page 3: Persona — tunes copy/recommendation framing app-wide.
            // Default is `retention`; every choice keeps the full feature set.
            OnboardingPageScroll {
                VStack(spacing: 24) {
                    Text("What brings you here?")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    VStack(spacing: 12) {
                        ForEach(UserPersona.allCases) { persona in
                            Button {
                                personaRaw = persona.rawValue
                                withAnimation { currentTab = 3 }
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
                                    if personaRaw == persona.rawValue {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.cobuxAccent)
                                    }
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

            // Page 4: Setup
            OnboardingPageScroll {
                VStack(spacing: 24) {
                    Text("Let's get started")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Cobux uses Claude AI to answer your questions. Enter your Anthropic API Key below.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

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
                        Text(trimmedAPIKey.isEmpty ? "Skip for now" : "Get Started")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(trimmedAPIKey.isEmpty ? Color.secondary.opacity(0.3) : Color.cobuxAccent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
                    }
                }
                .padding()
            }
            .tag(3)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(
            // Same dark backdrop family as VoiceModeView's -- both are always-dark,
            // full-screen, no-system-chrome moments regardless of the system color
            // scheme, so they share one gradient token instead of two near-identical
            // hardcoded hex values (this one was #1e1b4b -- CobuxColor.voiceGradient's
            // own first stop, byte-identical, just spelled out a second time).
            LinearGradient(colors: CobuxColor.voiceGradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        // The comment above promises the same "always-dark regardless of system
        // color scheme" behavior VoiceModeView/SpokenQuizView have -- but unlike
        // both of those, this view never actually forced it, and this screen
        // (unlike voice mode) can't inherit a dark override from anywhere else:
        // it's the very first thing a fresh install shows, before `themeRaw` in
        // CobuxApp has any value other than its `.system` default (`colorScheme`
        // == nil, i.e. "follow the device"). On a phone in Light Mode -- exactly
        // Gulab's first launch -- every unstyled `Text` here (`.primary`/
        // `.secondary`, pages 1, 2, and 4) rendered near-black on this near-black
        // gradient: real, close-to-unreadable contrast on a brand-new tester's
        // very first screen. Page 3 alone was readable, because it's the one
        // page that happens to hardcode `.foregroundStyle(.white)` throughout.
        .preferredColorScheme(.dark)
        .alert("Couldn't Save Key", isPresented: $showingKeychainFailureAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your API key couldn't be saved. You can try again, or tap \"Skip for now\" and add it later in Settings.")
        }
    }
}

/// Wraps a single onboarding page's content in a `ScrollView` sized to at
/// least fill the page (via `GeometryReader`), instead of the bare `VStack`
/// each page used to sit in directly. `TabView(.page)` never scrolls a page
/// on its own -- content that doesn't fit just clips silently at the bottom
/// of the screen. On a small phone (iPhone SE-class) with a larger Dynamic
/// Type accessibility size, page 3's three persona rows (each with a
/// wrapping title + subtitle) or page 4's description + field + button can
/// genuinely exceed the screen height, which used to mean the "Get
/// Started"/"Skip for now" button -- the only way page 4 completes
/// onboarding -- became unreachable. `minHeight: proxy.size.height` keeps
/// every page centered exactly as before whenever content fits, and makes
/// it scrollable instead of clipped whenever it doesn't.
private struct OnboardingPageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let desc: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(Color.cobuxAccent)
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
            }
        }
    }
}
