# Adding a new book to Cobux

The reusable process for turning a source PDF/EPUB into a real Cobux seed book — chapters,
summaries, key lessons, and highlights — the same way all 15 JSON-authored books (Attached,
12 Rules for Life, Sapiens, etc.) and the two hand-written medical textbooks (Robbins,
Microbiology) were built. Point a future session at this file plus a new PDF and say "author
this as a new Cobux book" — everything below is what that session needs to reproduce the
process end to end.

## Output: one `SeedBookDocument` JSON file

Goes in `Cobux/Resources/SeedBooks/<slug>.json`. Loaded automatically by
`Cobux/Services/SeedLoader.swift` on every app launch — no other registration needed. Schema
(defined in `SeedLoader.swift`):

```json
{
  "title": "Attached",
  "author": "Amir Levine, Rachel Heller",
  "coverColorHex": "#6366F1",
  "coverImageURL": null,
  "contentProfile": "propositional",
  "contentVersion": 1,
  "chapters": [
    {
      "title": "1. Decoding Relationship Behavior",
      "chapterNumber": 1,
      "summary": "A few sentences of real substance -- not a one-line blurb. Should let the AI chat and quiz generation actually reason about the chapter's content without needing the highlights.",
      "keyLessons": [
        "One complete, specific, testable claim the chapter makes -- not a topic label.",
        "Another one. Real books run 3-8 of these per chapter."
      ]
    }
  ],
  "highlights": [
    {
      "text": "A real, verbatim quote from the source -- never paraphrased, never invented.",
      "chapter": "1. Decoding Relationship Behavior",
      "tags": ["intimacy", "secure", "anxious", "avoidant"],
      "isReminder": false
    }
  ]
}
```

Field notes:
- `chapter.title` and `highlight.chapter` must match **exactly**, character for character —
  this is a free-text join today (`Highlight.chapter: String?`), not a foreign key. A typo
  silently orphans every highlight in that chapter from search/citations/quiz generation.
- Chapter titles are numbered (`"N. Title"` for whole books, `"N.M. Section: Title"` for a
  book authored at subsection granularity, e.g. Microbiology's `"3.1. General Bacteriology:
  Bacterial Taxonomy"`) — this isn't cosmetic, `tools/extract_figures.py` parses this exact
  numeric-prefix convention to map figures to chapters via the source PDF's own TOC.
- `contentVersion` starts at 1 for a new book. Bump it whenever you revise an already-shipped
  book's JSON — `SeedLoader.upsert` compares against `Book.seedContentVersion` and no-ops if
  the file's version isn't newer, so a revision that forgets this bump silently never reaches
  devices that already seeded the older cut (a real bug that happened once already).
- `tags` are free-form lowercase topic words — they feed `WisdomGraphService`'s tag merging.
- `isReminder: false` for basically everything; `true` is a legacy field from an earlier
  feature, not something new books need to set meaningfully.

## `contentProfile` — pick the right one, it changes real behavior

From `Cobux/Models/Book.swift`'s `BookContentProfile` enum (read that file's doc comments for
the authoritative definitions — this is a summary):

| Profile | When to use | Real books | Effect |
|---|---|---|---|
| `propositional` | Default for self-help/psychology/nonfiction with clear, extractable claims | Attached, 12 Rules, Sapiens, Dopamine Nation | Full cloze quiz generation, small enough to full-dump into chat context |
| `academicReference` | Large reference texts (hundreds of chapters/highlights) | Robbins, Microbiology | Same cloze generation, but retrieval-gated chat context (too big to full-dump) + exam-simulation quiz tone |
| `doctrine` | Dialogue/lecture format — highlights should capture the *resolved* position, not every voice in the conversation | The Courage to Be Disliked, The Meaning of It All | Cloze generation enabled |
| `narrative` | Memoir/anecdotal prose with no extractable propositional claims | Surely You're Joking Mr. Feynman, Greenlights | Verbatim quotes only, cloze generation **disabled** — nothing here should ever surface as a quiz question |
| `densePhilosophy` | Dense original philosophical/academic argument where paraphrasing risks misrepresenting the author's actual claim | The Denial of Death, Religion in the Making | Verbatim quotes with a gloss, cloze generation **disabled by default** given fabrication risk |

Getting this wrong doesn't crash anything, but a `narrative` book tagged `propositional` will
generate nonsense cloze quiz cards from anecdotes that were never meant to be tested.

## The actual authoring process

1. **Get the source.** A real PDF/EPUB you own, same as every existing book (Robbins/
   Microbiology/Attached/etc. source files live in `~/Downloads/`, not committed anywhere).
2. **Decide `contentProfile`** using the table above — this is a judgment call worth making
   explicitly before authoring starts, not defaulting to `propositional` for everything.
3. **Dispatch Fable to author the JSON.** Fable is this project's standing supervising
   architect for anything new (see the plan file) — book content authoring is no exception.
   Give it: the source PDF/text, the target `contentProfile`, this doc's schema, and the
   instruction that chapter summaries/key lessons should be **real editorial synthesis** (not
   filler) and highlights must be **genuinely verbatim** — copied exact text from the source,
   never paraphrased, never invented to sound plausible. Scale expectations from real books:
   propositional/doctrine/narrative books run roughly 6-50 chapters and 60-600 highlights
   depending on length; academic references run into the hundreds of each.
4. **Verbatim-verify.** This is the step that actually matters and is easy to skip under time
   pressure: spot-check (or fully check, for a shorter book) that every highlight's `text`
   field is byte-for-byte real source text, not a plausible-sounding hallucination. This was
   done for all 15 existing JSON books ("editorially reviewed for genuine quality... verbatim-
   verified against source" per the session that built them) — an LLM asked to "extract
   highlights" will occasionally smooth over or invent a quote that reads naturally but isn't
   actually in the book, and that's a real trust problem for a study app, not a nitpick.
5. **Editorial quality pass, separate from verbatim-verification.** Verbatim-checking catches
   fabrication; it doesn't catch a chapter summary that's technically accurate but shallow, or
   key lessons that are topic labels ("This chapter discusses X") instead of real testable
   claims. Fable should review for this too, ideally as a distinct pass/dispatch from the
   authoring pass itself, so the reviewer isn't grading its own homework.
6. **Save the file** as `Cobux/Resources/SeedBooks/<slug>.json` (slug = lowercase, no spaces —
   match the existing files' convention, e.g. `48lawsofpower.json`, `denialofdeath.json`).
7. **Pick a `coverColorHex`** — any real hex value works; `#6366F1` (the app's own resolved
   accent) is a safe default if you don't have a specific cover-derived color in mind.
8. **Regenerate and verify.** `xcodegen generate` (picks up the new file automatically — the
   whole `SeedBooks/` directory is a single `type: folder` reference in `project.yml`, so
   individual files never need registering), then a real `xcodebuild build` +
   `swift test --package-path CobuxCore` + `xcodebuild test` (or the CI run) + `swiftlint
   lint`, same checkpoint discipline as any other change.
9. **Bump the build, ship it.** Adding a book is exactly the kind of change that should ride
   in a real versioned build with a changelog entry (`Cobux/BuildInfo.swift`), archived and
   uploaded the same way every other release this session was — see the plan file's Phase 6 /
   release checklist for the concrete archive/export/upload steps if this is the first time
   doing it in a given session.

## Cost and effort, for planning purposes

Authoring a full book (chapter summaries + key lessons + verbatim highlights) through Fable is
a real, moderately expensive task — this is editorial synthesis across an entire book's worth
of source text, not a cheap one-shot call. Treat it with the same burn-rate awareness as any
other Fable dispatch (see `feedback-fable-burn-rate-awareness` memory): weigh necessity, and
don't chain many books through Fable back-to-back in one session without checking remaining
budget. A short book (Courage to Be Disliked, 6 chapters/101 highlights) is meaningfully
cheaper than a long one (Surely You're Joking, 40 chapters/582 highlights) — scale expectations
accordingly when planning how many books to add in one sitting.

## Image/diagram figures (optional, separate step)

If the source book has real extractable diagrams/photomicrographs worth captioning (mainly
relevant for reference-style books, not prose), that's a separate pipeline —
`tools/extract_figures.py` (free, local, chapter-mapped via the PDF's own TOC) +
`tools/caption_figures.py` (paid, Claude vision, ~$0.001/image). See those scripts' own doc
comments; not part of the core book-authoring flow above.
