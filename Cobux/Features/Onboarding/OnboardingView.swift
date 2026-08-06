import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @State private var apiKey = ""
    @State private var currentTab = 0

    var body: some View {
        TabView(selection: $currentTab) {
            // Page 1: Welcome
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
            .tag(0)

            // Page 2: Features
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
            .tag(1)

            // Page 3: Setup
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
                    if !apiKey.isEmpty {
                        _ = KeychainManager.save(key: KeychainManager.anthropicAPIKey, data: apiKey)
                    }
                    hasCompletedOnboarding = true
                }) {
                    Text(apiKey.isEmpty ? "Skip for now" : "Get Started")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(apiKey.isEmpty ? Color.secondary.opacity(0.3) : Color.cobuxAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: CobuxRadius.card))
                }
            }
            .padding()
            .tag(2)
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
                .frame(width: 40)

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
