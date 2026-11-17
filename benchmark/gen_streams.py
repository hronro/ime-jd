#!/usr/bin/env python3
"""Turn a Chinese corpus into keystroke streams both engines can replay.

Usage: gen_streams.py <core/tables> <corpus.txt> <out_dir>

Reads libjd's own tables (core/tables/*.txt, the same rows as the Rime
scheme's dictionaries) and segments the corpus greedily, longest word first,
into words that have a code on which the word can be picked from the first
page.

Stream encoding, one byte per event:
  0x20..0x7e  a literal key (letters, space, punctuation)
  0x01..0x06  "pick candidate (b-1) on the current page"
              libjd: jd_set_anchor(b-1) + space;  Rime: digit key b

Two streams are written:
  space.keys   every word is its code + space (or a selection)
  topup.keys   顶功: the space is left out wherever BOTH engines commit on the
               next word's first key -- the scheme's Lua topup rule and
               libjd's commit-and-jump (key not a child of the current node)
Alongside each: <stream>.expect, the text both engines must commit, and
<stream>.cats, one category byte per event for the per-category latencies.
"""
import sys
from pathlib import Path

tables_dir, corpus_path, out_dir = map(Path, sys.argv[1:4])
PAGE = 6  # the scheme's menu/page_size; the harness reads the same page from libjd
# The scheme's topup settings (keytao.schema.yaml: layout/topup, topup/*).
TOPUP = set("avuio;")
MIN_LEN, MAX_LEN = 4, 6

codes: dict[str, list[str]] = {}
for f in sorted(tables_dir.glob("*.txt")):
    for line in f.read_text(encoding="utf-8").split("\n"):
        s = line.strip(" \r")
        if not s or s.startswith("#") or "\t" not in s:
            continue
        v, k = s.split("\t", 1)
        codes.setdefault(k.strip(), []).append(v.strip())

prefixes = set()
for k in codes:
    for i in range(1, len(k) + 1):
        prefixes.add(k[:i])


def rime_rule_breaks(code: str) -> bool:
    """True when the scheme's Lua topup rule commits partway through `code`,
    so the code cannot be typed in full there (gllgle commits after gllg)."""
    if code[0] in TOPUP:  # topup_command: no topup logic for these
        return False
    for n in range(1, len(code)):  # n = input length before pressing code[n]
        prev, k = code[n - 1], code[n]
        if (prev in TOPUP and k not in TOPUP) or (prev not in TOPUP and k not in TOPUP and n >= MIN_LEN) or n >= MAX_LEN:
            return True
    return False


def usable(code: str) -> bool:
    # a-z only (';' picks the second candidate in libjd but is a code key in
    # the scheme), and not 'o'-initial: the scheme's Lua translator adds
    # date/time candidates there.
    return (code.isalpha() and code.isascii() and code.islower() and not code.startswith("o")
            and not rime_rule_breaks(code))


best: dict[str, tuple[int, str, int]] = {}  # value -> (cost, code, index)
for code, vals in codes.items():
    if not usable(code):
        continue
    for i, v in enumerate(vals[:PAGE]):
        # Rime's uniquifier drops repeats, so a selection is only portable
        # when everything ahead of it on this code is distinct.
        if len(set(vals[: i + 1])) != i + 1:
            break
        cost = len(code) + 1 + (0 if i == 0 else 0.5)
        if v not in best or (cost, code) < best[v][:2]:
            best[v] = (cost, code, i)

maxlen = max(len(v) for v in best)
# Punctuation that auto-commits the same text in both engines.
PUNCT = {"，": ",", "。": ".", "？": "?", "！": "!", "：": ":", "（": "(", "）": ")", "……": "^"}

text = corpus_path.read_text(encoding="utf-8")
events: list[tuple] = []  # ("w", code, index, value) | ("p", key, value)
i = 0
skipped = 0
while i < len(text):
    if text.startswith("……", i):
        events.append(("p", "^", "……"))
        i += 2
        continue
    c = text[i]
    if c in PUNCT:
        events.append(("p", PUNCT[c], c))
        i += 1
        continue
    for L in range(min(maxlen, len(text) - i), 0, -1):
        w = text[i : i + L]
        if w in best:
            _, code, idx = best[w]
            events.append(("w", code, idx, w))
            i += L
            break
    else:
        skipped += 1
        i += 1


def emit(topup: bool):
    # cats: 0 first key of a word, 1 later key, 2 first key that also commits
    # the previous word (顶功), 3 space, 4 selection, 5 punctuation
    keys = bytearray()
    cats = bytearray()
    expect = []
    pending_topup = False
    for n, ev in enumerate(events):
        if ev[0] == "p":
            keys += ev[1].encode()
            cats.append(5)
            expect.append(ev[2])
            continue
        _, code, idx, w = ev
        keys += code.encode()
        cats.append(2 if pending_topup else 0)
        cats += bytes([1]) * (len(code) - 1)
        pending_topup = False
        expect.append(w)
        if idx:
            keys.append(1 + idx)
            cats.append(4)
            continue
        nxt = events[n + 1] if n + 1 < len(events) else None
        if topup and nxt and nxt[0] == "w":
            k = nxt[1][0]
            ln = len(code)
            rime = code[0] not in TOPUP and (
                (code[-1] in TOPUP and k not in TOPUP)
                or (code[-1] not in TOPUP and k not in TOPUP and ln >= MIN_LEN)
                or ln >= MAX_LEN
            )
            jd = (code + k) not in prefixes
            if rime and jd:
                pending_topup = True
                continue  # the next key commits this word in both engines
        keys += b" "
        cats.append(3)
    assert len(keys) == len(cats)
    return bytes(keys), bytes(cats), "".join(expect)


out_dir.mkdir(parents=True, exist_ok=True)
for name, topup in (("space", False), ("topup", True)):
    keys, cats, expect = emit(topup)
    (out_dir / f"{name}.keys").write_bytes(keys)
    (out_dir / f"{name}.cats").write_bytes(cats)
    (out_dir / f"{name}.expect").write_text(expect, encoding="utf-8")
    words = sum(1 for e in events if e[0] == "w")
    sel = sum(1 for e in events if e[0] == "w" and e[2])
    print(f"{name}: {len(keys)} key events, {words} words ({sel} by selection), "
          f"{sum(1 for e in events if e[0]=='p')} punct, {len(expect)} chars out, "
          f"{keys.count(b' ')} spaces")
print(f"skipped corpus chars (digits/latin/unmapped): {skipped}")
