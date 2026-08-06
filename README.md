# Cobux

Your personal book wisdom companion — an iOS app for storing book highlights and chapter
summaries, then asking an AI to answer questions grounded *only* in what you've actually
stored, with citations back to which books it drew from.

If a book changed how you think, you shouldn't have to remember it perfectly to use it. Cobux
turns your own highlights into something you can actually talk to.

## What's here

This is the open-source version of Cobux's codebase — SwiftUI/SwiftData, no server, no
backend. The architecture, design system, quiz scheduler, and every feature are the real
production code. What's **not** here is the seed book content that ships in the private build
(see [Content](#content) below) — everything else is unmodified.

## Features

- **Library** — books, chapters, and highlights, stored locally via SwiftData.
- **AI Chat** — streaming replies from Claude (Anthropic API), grounded exclusively in your
  stored highlights, with the model declaring which books it actually drew from (not inferred
  from retrieval) so citation chips are always accurate. Book-scoped threads keep a
  conversation focused on one book; a general thread spans your whole library. "Symposium
  Mode" answers as each relevant book's author separately, then highlights where they'd
  disagree.
- **Voice Mode** — a hands-free conversational loop: listen, transcribe, ask Claude, speak the
  reply back as it streams in (sentence by sentence, not waiting for the whole response).
  Shares the same prompt-cache entry and conversation thread as text chat.
- **Quiz** — spaced-repetition review built on [FSRS-6](https://github.com/open-spaced-repetition/fsrs4anki)
  (the current Anki default), with free on-device question generation, Daily Review (a queue
  spanning your whole library), and Exam Countdown (compress reviews to a study deadline so
  nothing schedules past it).
- **Share Extension** — capture a quote from Kindle, Books, Safari, or anywhere else that
  shares plain text, straight into Cobux. Files it to a book, or leaves it "Unsorted" until you
  do.
- **Design system** — real light/dark tokens, per-book accent color, and a SwiftLint
  configuration (`.swiftlint.yml`) that structurally prevents the kind of drift (raw system
  colors, magic corner radii, duplicate navigation stacks) that's easy to accumulate by hand.
- **100% local-first** — everything lives on-device via SwiftData. The only external call is to
  the Anthropic API, using a key you provide yourself.

## Content

The private/production build ships with a real starter library — book highlights and chapter
summaries authored from books the developer owns. That content isn't included here, since it's
derived from commercially published books and this repo is public.

Concretely: `Cobux/Resources/SeedBooks/` is empty (JSON-authored books normally live there —
see `SeedBookDocument` in `Cobux/Services/SeedLoader.swift` for the exact schema), and
`Cobux/Services/SeedDataMicrobiology.swift`/`SeedDataRobbins.swift` (two textbooks that predate
the JSON approach and are still hand-written Swift) are stubbed as no-ops. **The app builds and
runs correctly with an empty library on first launch** — this was verified before publishing,
not assumed.

If you want to try it with real content, either:
1. Add your own books through the app's UI (Library → **+** → Add Book), or
2. Author a `SeedBookDocument` JSON file (schema in `SeedLoader.swift`) for a book you own or
   that's in the public domain, and drop it in `Cobux/Resources/SeedBooks/` — it'll seed on
   next launch.

## Setup

1. Open `Cobux.xcodeproj` in Xcode 17+ (or run `xcodegen generate` first if you've edited
   `project.yml`).
2. Select your own development team in each target's Signing & Capabilities (Cobux,
   CobuxWidgets, CobuxShareExtension) — you'll also need your own App Group identifier if you
   want the widget/Share Extension to work; the default `group.com.rajansharma.Cobux` won't be
   provisionable under your account.
3. Build and run on a device or simulator (iOS 17+).
4. In Settings → AI Chat, paste your own Anthropic API key (create one at
   [console.anthropic.com](https://console.anthropic.com)). It's stored in the iOS Keychain and
   sent only to Anthropic — never anywhere else.

## Architecture notes

- `CobuxCore/` — a local Swift package with zero SwiftUI/UIKit dependency: the FSRS scheduler,
  citation resolution, cost estimation, and other pure logic, unit-tested independently of the
  app (`swift test --package-path CobuxCore`, no simulator needed).
- `Cobux/DesignSystem/` — the single source of truth for colors, spacing, radii, and motion;
  `.swiftlint.yml`'s custom rules enforce that new code actually uses it.
- `CobuxWidgets/`, `CobuxShareExtension/` — app extensions, each re-including only the specific
  model/service files they need (see their `sources:` entries in `project.yml`) rather than
  depending on the whole app target.
- `.github/workflows/ci.yml` — builds the app + widget + extensions, runs `CobuxCore`'s test
  suite, runs the full app test suite on a simulator, and fails the build on any SwiftLint
  violation or uncommitted `project.yml`/`Cobux.xcodeproj` drift.
