#!/usr/bin/env python3
"""
Builds the medicines catalogue the phone app ships with (FR-12).

    ./scripts/build-medicines-catalogue.py            # rebuild from the PDF in docs/regulatory
    ./scripts/build-medicines-catalogue.py --check    # fail if the committed file is stale

Source: the Ethiopian Essential Medicines List, seventh edition (EFDA/GDL/067, October 2024),
stored verbatim in docs/regulatory/. Its main table has three columns — a serial number, a
generic name, and "Dosage Form and Strength" — grouped under pharmacotherapeutic headings.
This turns each (generic name, dosage form, strength) into one catalogue entry, which is
what a pharmacy stocks and prices: "Amoxicillin 500mg capsule", not "Amoxicillin".

It needs `pdftotext` (poppler). The output is committed, so CI and a normal build never run
this; it is run by hand when EFDA publishes a new edition.

What this deliberately does NOT do:

  * It does not mark anything as controlled. Whether a medicine is a controlled substance is
    a regulatory fact behind assumption A-1, and the server refuses to create a controlled
    product until that clears (ADR-024). A list of names is not a regulatory reading.
  * It does not invent pack sizes or prices. The list has neither.
  * It does not guess at a row it cannot read. A line that does not parse as a dosage form
    is left out, and the medicine is still listed by name, so the owner can add the form.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "docs/regulatory/EFDA-GDL-067-essential-medicines-list-2024.pdf"
OUTPUT = REPO / "apps/mobile/assets/catalogue/medicines.json"

EDITION = "Ethiopian Essential Medicines List, 7th edition (EFDA/GDL/067), October 2024"

TABLE_START = "Pharmacotherapeutic Classification of Medicines"
TABLE_END = re.compile(r"^\s*Annex 1\s*$")

CATEGORY = re.compile(r"^\s*([A-Z]{2})\.?\s?(\d{3,4})((?:\.\d+)*)\.?\s*(\S.*)$")
ITEM = re.compile(r"^\s{0,3}(\d{1,3})\.?\s+(\S.*)$")
FURNITURE = re.compile(
    r"Document No\.|^\s*Ethiopian Essential Medicines List\s*$|^\s*S\.\s*$|"
    r"^\s*No\s+Generic name|^\s*\d+\s*$"
)

# The words a dosage-form label starts with. A closed list on purpose: the form column also
# holds compositions ("Glucose: 75 mEq") and notes, and anything not on this list is dropped
# rather than turned into a product nobody stocks.
FORM_WORDS = (
    "tablet", "capsule", "caplet", "injection", "syrup", "suspension", "solution", "oral",
    "powder", "cream", "ointment", "gel", "lotion", "drop", "drops", "eye", "ear", "nasal",
    "suppository", "pessary", "vaginal", "rectal", "inhal", "aerosol", "spray", "patch",
    "transdermal", "enema", "liquid", "elixir", "granule", "lozenge", "shampoo", "paste",
    "implant", "infusion", "emulsion", "mouthwash", "linctus", "tincture", "soap", "foam",
    "nebuli", "respirator", "metered", "dry", "concentrate", "intrauterine", "ophthalmic",
    "topical", "sublingual", "chewable", "dispersible", "scored", "film", "ampoule", "vial",
    "mixture", "jelly", "irrigation", "pellet", "sachet", "dental", "medicinal", "gas",
    "pre-filled", "prefilled", "pen", "cartridge", "depot", "ring", "bar", "stick", "swab",
)

# What one of them is counted in at the counter: the product's base unit (FR-11). First match
# wins, so the more specific words come first.
UNITS = (
    ("tablet", "tablet"), ("caplet", "tablet"), ("capsule", "capsule"),
    ("lozenge", "lozenge"), ("suppository", "suppository"), ("pessary", "pessary"),
    ("patch", "patch"), ("sachet", "sachet"), ("granule", "sachet"),
    ("inhal", "inhaler"), ("aerosol", "inhaler"), ("spray", "bottle"),
    ("implant", "implant"), ("intrauterine", "piece"), ("ring", "piece"),
    ("cream", "tube"), ("ointment", "tube"), ("gel", "tube"), ("paste", "tube"),
    ("jelly", "tube"),
    ("injection", "ampoule"), ("infusion", "bag"), ("pre-filled", "syringe"),
    ("prefilled", "syringe"), ("pen", "pen"), ("vial", "vial"), ("ampoule", "ampoule"),
    ("powder for injection", "vial"),
    ("powder", "sachet"),
    ("soap", "bar"), ("bar", "bar"),
)
DEFAULT_LIQUID_UNIT = "bottle"


def pdf_lines(pdf: Path) -> list[str]:
    text = subprocess.run(
        ["pdftotext", "-layout", str(pdf), "-"], check=True, capture_output=True, text=True
    ).stdout
    lines = text.splitlines()
    # The phrase also appears in the table of contents; the table is its last occurrence.
    start = max(i for i, line in enumerate(lines) if line.strip() == TABLE_START)
    end = next(i for i in range(start, len(lines)) if TABLE_END.match(lines[i]))
    return lines[start + 1 : end]


# The list tags antibiotics with their WHO AWaRe group. Useful to a prescriber, noise on a
# till: nobody searches for "Amoxicillin (Access)".
AWARE = re.compile(r"\s*\((Access|Watch|Reserve)\)", re.IGNORECASE)

# Longer than this and it is a paragraph that slipped through, not a product name.
MAX_DISPLAY = 110


# "(as trihydrate)", "(as sodium salt)": which salt the strength is expressed as. True, and
# not how anyone names the box — "Amoxicillin 500mg capsule" is what gets searched for.
SALT = re.compile(r"\s*\(as [^()]*\)?", re.IGNORECASE)


def tidy(text: str) -> str:
    text = AWARE.sub("", text).replace("*", "")
    text = SALT.sub("", text).replace("dispersaible", "dispersible")
    text = re.sub(r"\s+", " ", text).strip(" ,;:.")
    text = re.sub(r"\s*\+\s*", " + ", text)
    text = re.sub(r"(\+ )+\+ ", "+ ", text)
    text = re.sub(r"(?<=\w)\(", " (", text)
    return text.strip()


def is_form(label: str) -> bool:
    low = label.lower()
    # "Powder for dilution, each sachet for 1 liter contains" introduces a composition.
    if len(label) > 45 or "contain" in low or "each" in low:
        return False
    words = re.split(r"[\s/(,-]+", low)
    return bool(words) and any(words[0].startswith(w) for w in FORM_WORDS)


def split_strengths(text: str) -> list[str]:
    """Splits "20mg, 40mg in vial" on top-level commas (or semicolons); inside (...) is kept."""
    parts, depth, current = [], 0, ""
    for ch in text:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth = max(0, depth - 1)
        if ch in ",;" and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    parts.append(current)
    return [tidy(p) for p in parts if tidy(p)]


def unit_for(form: str) -> str:
    low = form.lower()
    if low.startswith("powder for inj"):
        return "vial"
    words = re.split(r"[^a-z-]+", low)
    for word, unit in UNITS:
        # Whole words, by prefix: "pen" must not match "suspension".
        if any(w.startswith(word) for w in words):
            return unit
    return DEFAULT_LIQUID_UNIT


def parse(lines: list[str]) -> list[dict]:
    entries: list[dict] = []
    category = group = ""
    name_parts: list[str] = []
    forms: list[list[str]] = []  # [label, strengths text]
    form_col = 30
    in_note = False

    def flush() -> None:
        nonlocal name_parts, forms
        name = tidy(" ".join(name_parts))
        if name:
            emitted = False
            for label, strengths in forms:
                label = tidy(label)
                for strength in split_strengths(strengths) or [""]:
                    entries.append(
                        {
                            "name": name,
                            "form": label,
                            "strength": strength,
                            "unit": unit_for(label),
                            "category": category,
                            "group": group,
                        }
                    )
                    emitted = True
            if not emitted:
                entries.append(
                    {"name": name, "form": "", "strength": "", "unit": "piece",
                     "category": category, "group": group}
                )
        name_parts, forms = [], []

    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            in_note = False
            continue
        header = re.search(r"Dosage Form and Strength", line)
        if header:
            form_col = header.start()
            continue
        if FURNITURE.search(line):
            continue

        heading = CATEGORY.match(line)
        if heading and len(line) - len(line.lstrip()) < 4:
            flush()
            code, number, sub_number, title = heading.groups()
            title = tidy(title).lstrip(". ")
            if number == "000":
                category, group = title, title
            elif len(title) < 6:
                # "FE.100. Oral" under "Fluids and electrolytes": too short to stand alone.
                group = f"{category} — {title.lower()}"
            else:
                group = title
            continue

        item = ITEM.match(line)
        indent = len(line) - len(line.lstrip())
        if item and indent < 4:
            flush()
            in_note = False
            rest = item.group(2)
            # Name and form share the line, separated by the column gap.
            offset = line.index(rest)
            cut = max(form_col - 3 - offset, 0)
            gap = re.search(r"\s{2,}", rest[max(cut - 6, 0):]) if len(rest) > cut else None
            if gap:
                at = max(cut - 6, 0) + gap.start()
                name_parts = [rest[:at]]
                right = rest[at:].strip()
            else:
                name_parts, right = [rest], ""
                # The column gap collapsed to one space: "… citrate Tablet: 50mg, 100mg".
                # Split at the first capitalised word that begins a known dosage form.
                colon = rest.find(":")
                if colon > 0:
                    for word in re.finditer(r"(?<=\s)[A-Z]", rest[:colon]):
                        if is_form(rest[word.start():colon]):
                            name_parts = [rest[: word.start()]]
                            right = rest[word.start():]
                            break
        elif indent < form_col - 4 and name_parts:
            # Still in the name column: the generic name wraps over several lines, and a
            # form may sit beside the wrapped part.
            gap = re.search(r"\s{2,}", line.strip())
            if gap and indent + gap.start() < form_col + 2:
                left = line.strip()[: gap.start()]
                right = line.strip()[gap.end():]
            else:
                left, right = line.strip(), ""
            if left.startswith("*"):
                in_note = True
                continue
            if re.match(r"^(NB|Note)\b", left):
                # A remark in the name column, followed by an unnumbered list it applies
                # to. The numbered medicine above it is complete; nothing after it is one.
                flush()
                continue
            if "=" in left or left.endswith(":"):
                continue  # a composition table, not part of the name
            name_parts.append(left)
        else:
            right = line.strip()

        if not right or not name_parts:
            continue
        if right.startswith("*") or right.lower().startswith("note"):
            in_note = True
            continue
        labelled = re.match(r"^([A-Za-z][^:]{1,60}):\s*(.*)$", right)
        if labelled and is_form(labelled.group(1)):
            in_note = False
            forms.append([labelled.group(1), labelled.group(2)])
        elif labelled:
            # A labelled line that is not a dosage form: a composition or a remark.
            in_note = True
        elif forms and not in_note:
            forms[-1][1] += " " + right  # strengths wrapped onto the next line

    flush()
    return entries


def catalogue(entries: list[dict]) -> dict:
    seen: set[tuple] = set()
    items = []
    for e in entries:
        if len(e["name"]) > 80 or ":" in e["name"]:
            continue  # a row whose columns ran together; not a name anyone would pick
        display = " ".join(p for p in (e["name"], e["strength"], e["form"].lower()) if p)
        if len(display) > MAX_DISPLAY:
            # Keep the medicine, drop the unreadable detail; the owner types the form.
            e = {**e, "form": "", "strength": "", "unit": "piece"}
            display = e["name"]
        key = (display.lower(),)
        if key in seen:
            continue
        seen.add(key)
        items.append(
            {
                "n": display,
                "g": e["name"],
                "f": e["form"],
                "s": e["strength"],
                "u": e["unit"],
                "c": e["group"] or e["category"],
            }
        )
    items.sort(key=lambda i: i["n"].lower())
    return {"source": EDITION, "count": len(items), "medicines": items}


def render(data: dict) -> str:
    # One medicine per line: a new edition then reads as a diff of medicines, not as one
    # changed line a megabyte long.
    rows = ",\n".join(
        "    " + json.dumps(m, ensure_ascii=False, separators=(",", ":"))
        for m in data["medicines"]
    )
    return (
        "{\n"
        f'  "source": {json.dumps(data["source"])},\n'
        f'  "count": {data["count"]},\n'
        '  "medicines": [\n' + rows + "\n  ]\n}\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--pdf", type=Path, default=SOURCE)
    args = parser.parse_args()

    out = render(catalogue(parse(pdf_lines(args.pdf))))
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != out:
            print(f"{OUTPUT.relative_to(REPO)} is stale; run this script without --check")
            return 1
        print("medicines catalogue is up to date")
        return 0
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(out, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
