#!/usr/bin/env python3
"""Generate LyricsX's okurigana fallback from KANJIDIC2 and Jiten Global frequency ranks."""
import argparse
import csv
import gzip
import hashlib
import io
import re
from collections import defaultdict
from pathlib import Path
from xml.etree import ElementTree

OKURIGANA = re.compile(r"([ぁ-ゖー]+)\.([ぁ-ゖー]+)")
CODE_TYPES = {"ucs", "jis208", "jis212", "jis213"}
DEFAULT_OUTPUT = (Path(__file__).resolve().parents[1]
                  / "LyricsX/Supporting Files/JapaneseOkurigana.tsv")


def read_kanjidic(source):
    root = ElementTree.fromstring(gzip.decompress(source))
    characters = root.findall("character")
    codes, readings, aliases = {}, defaultdict(set), defaultdict(set)
    for entry in characters:
        glyph = entry.findtext("literal")
        if not glyph or len(glyph) != 1:
            continue
        for code in entry.findall("codepoint/cp_value"):
            kind = code.get("cp_type")
            if kind in CODE_TYPES:
                codes[kind, code.text] = glyph
        for reading in entry.findall(".//reading[@r_type='ja_kun']"):
            if match := OKURIGANA.fullmatch(reading.text or ""):
                readings[glyph].add(match.groups())
    for entry in characters:
        glyph = entry.findtext("literal")
        for variant in entry.findall("misc/variant"):
            other = codes.get((variant.get("var_type"), variant.text))
            if other and other != glyph:
                aliases[glyph].add(other)

    version = root.findtext("header/database_version")
    if not version or not readings:
        raise ValueError("Expected versioned KANJIDIC2 with dotted kun readings")
    variants = {glyph: {other for other in related if glyph in aliases.get(other, ())}
                for glyph, related in aliases.items()}
    entries = {}
    for glyph in readings.keys() | variants.keys():
        forms = readings[glyph].copy()
        # Use only reciprocal, explicitly encoded variants, not transitive
        # links or a generic traditional-to-simplified Chinese conversion.
        for other in variants.get(glyph, ()):
            forms.update(readings.get(other, ()))
        if forms:
            entries[glyph] = forms
    return version, entries, variants


def ambiguous_forms(forms):
    # Only exact forms at successive token boundaries can both match the
    # same input. They must have equal or prefix-related okurigana.
    return {(stem, suffix) for stem, suffix in forms
            if any(stem != other_stem and (suffix.startswith(other_suffix) or other_suffix.startswith(suffix))
                   for other_stem, other_suffix in forms)}


def frequency_ranks(source, targets):
    rows = csv.DictReader(io.StringIO(source.decode("utf-8-sig"), newline=""))
    if not {"Word", "Form", "Rank"} <= set(rows.fieldnames or ()):
        raise ValueError("Expected the Jiten Global CSV with Word, Form, Rank")
    ranks = {}
    for row in rows:
        key = row["Word"], row["Form"]
        if key in targets:
            rank = int(row["Rank"])
            if rank <= 0:
                raise ValueError(f"Expected positive frequency rank for {key}")
            ranks[key] = min(rank, ranks.get(key, rank))
    if not ranks:
        raise ValueError("The frequency list has no matches for ambiguous KANJIDIC2 forms")
    return ranks


def generate(source, frequency):
    version, entries, variants = read_kanjidic(source)
    ambiguous = {glyph: ambiguous_forms(forms) for glyph, forms in entries.items()}
    targets = {(written + suffix, stem + suffix)
               for glyph, forms in ambiguous.items()
               for stem, suffix in forms
               for written in {glyph} | variants.get(glyph, set())}
    ranks = frequency_ranks(frequency, targets)
    yield f"# KANJIDIC2 {version}; source SHA256: {hashlib.sha256(source).hexdigest()}"
    yield f"# Jiten Global frequency CSV; source SHA256: {hashlib.sha256(frequency).hexdigest()}"
    yield "# Glyph<TAB>okurigana<TAB>kanji reading<TAB>optional frequency rank (lower is more common)"
    for glyph, forms in sorted(entries.items()):
        for stem, suffix in sorted(forms, key=lambda form: (form[1], form[0])):
            rank = None
            if (stem, suffix) in ambiguous[glyph]:
                reading = stem + suffix
                rank = ranks.get((glyph + suffix, reading))
                if rank is None:
                    rank = min((ranks[other + suffix, reading] for other in variants.get(glyph, ())
                                if (other + suffix, reading) in ranks), default=None)
            row = f"{glyph}\t{suffix}\t{stem}"
            yield row if rank is None else f"{row}\t{rank}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="downloaded kanjidic2.xml.gz")
    parser.add_argument("frequency", type=Path, help="Jiten Global frequency CSV")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    args.output.write_bytes(("\n".join(generate(args.source.read_bytes(), args.frequency.read_bytes())) + "\n").encode())


if __name__ == "__main__":
    main()
