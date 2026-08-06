#!/usr/bin/env python3
"""Zero-cost local triage: does this PDF contain real extractable figures?
Distinguishes embedded diagrams/photos from full-page scans and layout
artifacts. Run BEFORE any paid vision/captioning call -- no network, no API
key, just `pdfinfo`/`pdfimages` (poppler, already a project dependency via
`pdftotext`). Exists because a naive "caption every image in every book"
pass would burn API calls scanning full-page scans (476 in one 48-Laws-style
scanned copy) and produce junk `Figure` rows for scrapbook photos in memoirs
-- this filters both out for $0 before Cobux's real image-extraction
pipeline (still gated on Rajan's own Anthropic key) ever runs."""
import subprocess, sys, re

MIN_EDGE   = 300    # px: below this it's a stencil/rule/artifact
COVERAGE   = 0.85   # frac of page covered -> it's a page scan, not a figure
SCAN_RATIO = 0.90   # >=this many imgs/page -> scanned book
MIN_FIGS   = 8      # fewer real figures than this -> not worth a pass

def triage(path):
    info = subprocess.run(["pdfinfo", path], capture_output=True, text=True).stdout
    pages = int(re.search(r"Pages:\s+(\d+)", info).group(1))
    m = re.search(r"Page size:\s+([\d.]+) x ([\d.]+)", info)
    pw_in, ph_in = float(m.group(1))/72, float(m.group(2))/72
    rows = subprocess.run(["pdfimages", "-list", path], capture_output=True, text=True).stdout.splitlines()[2:]
    figs = scans = 0
    for L in rows:
        p = L.split()
        if len(p) < 14 or p[2] != "image":
            continue
        try:
            w, h, ppi = int(p[3]), int(p[4]), float(p[12])
        except ValueError:
            continue
        if w < MIN_EDGE or h < MIN_EDGE:
            continue  # artifact
        if ppi <= 0:
            figs += 1
            continue
        if (w / ppi) / pw_in > COVERAGE and (h / ppi) / ph_in > COVERAGE:
            scans += 1  # full-page scan
        else:
            figs += 1
    total = figs + scans
    # A scanned book has ~one page-sized image on essentially EVERY page.
    # Guard on the per-page ratio, not scans/total: a text PDF with 2 stray
    # page-sized images would otherwise be misread as a full scan.
    if total / pages >= SCAN_RATIO and scans / total > 0.5:
        return pages, figs, scans, "SCANNED -- skip (no real figures)"
    if figs >= MIN_FIGS:
        return pages, figs, scans, f"RUN PASS -- {figs} figures"
    return pages, figs, scans, "skip (too few figures)"

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: figure_triage.py <pdf> [pdf ...]")
        sys.exit(1)
    for path in sys.argv[1:]:
        try:
            pg, f, s, v = triage(path)
            print(f"{f:>4} fig {s:>4} scan {pg:>4}pg  {v:38} {path.split('/')[-1][:44]}")
        except Exception as e:
            print(f"  ERR {e} :: {path}")
