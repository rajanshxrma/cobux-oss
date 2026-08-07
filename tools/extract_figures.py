#!/usr/bin/env python3
"""Extracts real figures (diagrams/photomicrographs, not decorative artifacts) from a source
PDF, downscales them for app bundling, and assigns each to a chapter using the PDF's own
embedded bookmark outline matched against the app's real Chapter titles (from the Swift seed
file) -- not a guess, an actual page lookup keyed on each chapter's own numeric prefix (e.g.
"3.1." or "12."), which is robust to different books mixing single-level (Robbins: "1.", "2.",
...) and multi-level (Microbiology: "1.", "2.", "3.1.", "3.2.", ...) chapter numbering across
different TOC outline depths. Zero paid API calls; this stage is entirely free and local.
Produces a manifest.json consumed by caption_figures.py (the paid stage).

Usage: extract_figures.py <pdf> <book_title> <chapters_swift_file> <out_dir>
"""
import fitz
import re
import sys
import json
import os


MIN_EDGE = 300
COVERAGE = 0.85


def load_chapters(swift_path):
    """Pulls Chapter(title: "...") strings out of a SeedDataX.swift file, in source order --
    this is the ground truth for what chapters the app actually has. Skips commented-out lines
    (a `//` before the match on the same line) so a stray mention in a doc comment doesn't count
    as a real chapter. Returns [(numeric_prefix, full_title), ...]."""
    chapters = []
    for line in open(swift_path, encoding="utf-8"):
        idx = line.find('Chapter(title:')
        if idx == -1:
            continue
        if "//" in line and line.index("//") < idx:
            continue
        m = re.search(r'Chapter\(title:\s*"((?:[^"\\]|\\.)*)"', line)
        if not m:
            continue
        title = m.group(1)
        pm = re.match(r"^(\d+(?:\.\d+)*)\.", title)
        if pm:
            chapters.append((pm.group(1), title))
    return chapters


def toc_numeric_pages(doc):
    """Maps numeric prefix -> earliest page it appears at, across ALL TOC levels/entries whose
    title starts with a chapter-number pattern. A dict (not a list) because the same numeric
    prefix can legitimately appear at more than one TOC level in some books (e.g. a chapter
    entry AND its own first subsection sharing a title); the first (lowest page) occurrence is
    the chapter's true start."""
    pages = {}
    for _lvl, title, page in doc.get_toc():
        m = re.match(r"^(\d+(?:\.\d+)*)[.\s]", title)
        if not m:
            continue
        prefix = m.group(1)
        if prefix not in pages or page < pages[prefix]:
            pages[prefix] = page
    return pages


def build_ranges(chapters, toc_pages, page_count):
    """Chapter N's page range runs from its own TOC start to just before the NEXT app chapter's
    TOC start (not the next TOC entry overall, which could be a subsection already counted
    inside chapter N) -- this is what makes the ranges correctly nest Microbiology's "3.1."/
    "3.2." subsections inside "3"'s overall span when the app itself only seeded top-level "3.x"
    entries as separate chapters, and correctly NOT nest them when the app also has a bare "3."
    the following chapter's own numeric prefix, so multi-level books stay unambiguous."""
    starts = []
    missing = []
    for prefix, title in chapters:
        if prefix not in toc_pages:
            missing.append(title)
            continue
        starts.append((title, toc_pages[prefix]))
    if missing:
        print(f"  WARNING: {len(missing)} app chapters have no matching TOC entry, will get zero figures: {missing[:5]}{'...' if len(missing) > 5 else ''}")
    starts.sort(key=lambda x: x[1])
    ranges = []
    for i, (title, start) in enumerate(starts):
        end = starts[i + 1][1] - 1 if i + 1 < len(starts) else page_count
        ranges.append((title, start, end))
    return ranges


def chapter_for_page(ranges, page):
    for title, start, end in ranges:
        if start <= page <= end:
            return title
    return None


def extract(pdf_path, book_title, chapters_swift, out_dir):
    doc = fitz.open(pdf_path)

    chapters = load_chapters(chapters_swift)
    toc_pages = toc_numeric_pages(doc)
    ranges = build_ranges(chapters, toc_pages, doc.page_count)
    matched = sum(1 for c in chapters if c[0] in toc_pages)
    print(f"{book_title}: matched {matched}/{len(chapters)} app chapters to real TOC pages")

    os.makedirs(out_dir, exist_ok=True)
    book_token = re.sub(r"[^a-z0-9]+", "-", book_title.lower()).strip("-")

    manifest = []
    for page_index in range(doc.page_count):
        page = doc[page_index]
        page_num = page_index + 1
        page_w, page_h = page.rect.width, page.rect.height  # points, matches get_image_rects' units
        for img_index, img in enumerate(page.get_images(full=True)):
            xref = img[0]
            try:
                base = doc.extract_image(xref)
            except Exception:
                continue
            w, h = base["width"], base["height"]
            if w < MIN_EDGE or h < MIN_EDGE:
                continue
            # Real placement size on the page (points), NOT derived from the native pixel
            # dimensions -- computing "DPI" from w/page_w and then dividing back by that same
            # DPI to get a "placed size" is a tautology that always reports 100% coverage.
            # get_image_rects() gives the actual drawn rectangle, which is what a true
            # full-page-scan check needs.
            rects = page.get_image_rects(xref)
            if rects:
                r = rects[0]
                if r.width / page_w > COVERAGE and r.height / page_h > COVERAGE:
                    continue  # full-page scan, not a figure

            chapter_title = chapter_for_page(ranges, page_num)
            if chapter_title is None:
                continue  # front matter / index / appendix -- not in any real chapter

            # JPEG, not PNG -- a lossless PNG at 1024px averaged ~670KB across a first test
            # batch (789MB for just Robbins' 1177 figures alone), which would put the full
            # ~2200-figure set well over a gigabyte in the app bundle. Quality 85 JPEG is ~4.5x
            # smaller for this kind of photomicrograph/diagram content with no visible quality
            # loss at in-app display size -- this is a study aid, not archival print output.
            file_name = f"{book_token}_p{page_num:04d}_{img_index}.jpg"
            out_path = os.path.join(out_dir, file_name)

            try:
                pix = fitz.Pixmap(doc, xref)
                if pix.n - pix.alpha >= 4:
                    pix = fitz.Pixmap(fitz.csRGB, pix)
                max_edge = max(pix.width, pix.height)
                if max_edge > 1024:
                    scale = 1024 / max_edge
                    pix = fitz.Pixmap(pix, int(pix.width * scale), int(pix.height * scale))
                pix.save(out_path, jpg_quality=85)
            except Exception as e:
                print(f"  skip xref {xref} p{page_num}: {e}")
                continue

            manifest.append({
                "fileName": file_name,
                "page": page_num,
                "book": book_title,
                "chapter": chapter_title,
            })

    manifest_path = os.path.join(out_dir, f"{book_token}_manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    by_chapter = {}
    for m in manifest:
        by_chapter[m["chapter"]] = by_chapter.get(m["chapter"], 0) + 1
    print(f"  {len(manifest)} figures extracted, {len(by_chapter)}/{len(chapters)} chapters represented")
    print(f"  manifest: {manifest_path}")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("usage: extract_figures.py <pdf> <book_title> <chapters_swift_file> <out_dir>")
        sys.exit(1)
    extract(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
