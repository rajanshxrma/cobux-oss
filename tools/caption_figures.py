#!/usr/bin/env python3
"""Paid stage: sends each extracted figure through Claude vision to (a) reject anything that
isn't a genuine informative diagram/photomicrograph (table fragments, stray decorative marks,
running headers misidentified as images) and (b) write a short caption for the ones that pass.
Reads a manifest.json from extract_figures.py, writes an updated manifest with `caption` filled
in and rejected entries removed. Uses ANTHROPIC_API_KEY from the environment -- never pass a key
on the command line or hardcode one here.
"""
import sys
import os
import json
import base64
import time
import anthropic

MODEL = "claude-haiku-4-5"

SYSTEM = """You triage medical textbook figures for a study app. For each image, decide: is this
a genuine informative diagram, illustration, or photomicrograph a medical student would want to
study (anatomy, pathology mechanism, clinical photo, histology slide, flowchart, etc.)? Reject
anything that is decorative, a stray mark, a table fragment misidentified as an image, a running
header/footer graphic, or too degraded/cropped to be useful on its own.

Respond with ONLY a JSON object, no other text: {"keep": true/false, "caption": "..."}
If keep is false, caption must be an empty string. If keep is true, caption must be ONE concise
sentence (under 25 words) describing what the figure shows, written for a medical student
reviewing it later without the surrounding textbook page for context."""


def caption_one(client, image_path):
    with open(image_path, "rb") as f:
        data = base64.standard_b64encode(f.read()).decode("utf-8")
    message = client.messages.create(
        model=MODEL,
        max_tokens=150,
        system=SYSTEM,
        messages=[{
            "role": "user",
            "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": data}},
                {"type": "text", "text": "Triage and caption this figure."},
            ],
        }],
    )
    text = message.content[0].text.strip()
    usage = message.usage
    parsed = _parse_response(text)
    return parsed, usage


def _parse_response(text):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    # Model occasionally wraps in a code fence despite instructions -- strip and retry.
    stripped = text.strip("`").removeprefix("json").strip()
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass
    # Model occasionally appends trailing prose after a well-formed JSON object instead of
    # emitting ONLY the object as instructed -- json.JSONDecoder.raw_decode parses just the
    # first valid JSON value and reports where it stopped, ignoring whatever follows, instead
    # of failing outright the way json.loads does on trailing data. This alone accounted for
    # ~2.5% of all requests erroring out and being silently dropped in the first full run.
    decoder = json.JSONDecoder()
    obj, _ = decoder.raw_decode(text)
    return obj


def main(manifest_path, image_dir, out_path):
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ANTHROPIC_API_KEY not set in environment", file=sys.stderr)
        sys.exit(1)
    client = anthropic.Anthropic(api_key=api_key)

    manifest = json.load(open(manifest_path))
    results = []
    total_in, total_out = 0, 0
    kept, rejected, errors = 0, 0, 0

    for i, entry in enumerate(manifest):
        image_path = os.path.join(image_dir, entry["fileName"])
        try:
            parsed, usage = caption_one(client, image_path)
        except Exception as e:
            print(f"  ERROR {entry['fileName']}: {e}")
            errors += 1
            continue
        total_in += usage.input_tokens
        total_out += usage.output_tokens
        if parsed.get("keep"):
            entry["caption"] = parsed["caption"]
            results.append(entry)
            kept += 1
        else:
            rejected += 1
        print(f"[{i+1}/{len(manifest)}] {entry['fileName']}: keep={parsed.get('keep')} caption={parsed.get('caption', '')[:70]}")

    json.dump(results, open(out_path, "w"), indent=2)

    # Haiku 4.5 published rates: $1/M input, $5/M output (see CobuxCore/RateTable.swift for the
    # app's own authoritative copy of this pricing -- duplicated here only for a quick estimate).
    cost = (total_in / 1_000_000) * 1.0 + (total_out / 1_000_000) * 5.0
    print(f"\nkept={kept} rejected={rejected} errors={errors}")
    print(f"tokens: {total_in} in, {total_out} out -- ${cost:.4f} for this batch")
    if kept + rejected > 0:
        print(f"~${cost / (kept + rejected):.5f} per image -- projected for 1692 images: ${cost / (kept + rejected) * 1692:.2f}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("usage: caption_figures.py <manifest.json> <image_dir> <out_manifest.json>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
