#!/usr/bin/env python3
"""Regenerate core/tables/*.txt from the upstream KeyTao Rime dictionaries.

Upstream is https://github.com/xkinput/KeyTao, directory `rime/`. Each of our
seven tables mirrors exactly one `*.dict.yaml` there. The conversion is small:
drop the Rime front matter, drop the `weight` column, keep `text\tcode` in
upstream order.

Order is the payload, not decoration. We have no weight column, so a
candidate's position in the file *is* its priority: within a file for entries
sharing a code, and across files via the 1..7 order `core/build.zig` feeds to
gen_trie. Upstream weights are rank indices with a per-file base (single 10-14,
phrase 100-102, supplement 100-106, link 10000-10001), and lower means higher
priority -- `bjekvo` is `(100, 不是) (101, 不实) (102, 布施)`. Upstream already
writes every group in that order, so the ascending sort here is a no-op that
exists to make the invariant explicit and to shout if upstream ever flips it.

Everything is validated before anything is written, so a bad sync fails here
rather than surfacing later as a cryptic error out of gen_trie or trie.zig.

Usage:
    python3 core/scripts/update-tables.py            # sync
    python3 core/scripts/update-tables.py --check    # exit 1 if out of date

Exit codes: 0 ok / up to date, 1 --check found drift, 2 fetch or validation
failure (nothing written).

After a sync:  cd core && zig build test --summary all
"""

import argparse
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

UPSTREAM_REPO = "xkinput/KeyTao"
UPSTREAM_REF = "master"
RAW_BASE = f"https://raw.githubusercontent.com/{UPSTREAM_REPO}/{UPSTREAM_REF}/rime/"

USER_AGENT = "ime-jd-update-tables/1.0 (+https://github.com/hronro/ime-jd)"
TIMEOUT_S = 30
RETRIES = 2
RETRY_BACKOFF_S = (1, 3)

TABLES_DIR = Path(__file__).resolve().parent.parent / "tables"


@dataclass(frozen=True)
class TableSpec:
    local_name: str
    upstream_name: str
    dict_name: str  # expected front-matter `name:`; catches a redirect or a bad URL
    title: str


# Order matters twice over: it is the argv order in core/build.zig, which sets
# cross-file candidate priority, and it is the order of this report.
#
# `1.single` carries upstream's already-merged super-chars, which is what its
# title claims. If upstream ever splits them back out into
# keytao.extended.dict.yaml, that title goes stale and this mapping needs a
# second source file -- the front-matter guard below will not catch that on its
# own, since the file would still parse cleanly.
TABLES: tuple[TableSpec, ...] = (
    TableSpec("1.single.txt", "keytao.single.dict.yaml", "keytao.single", "# 单字（已合并超级字词）"),
    TableSpec("2.phrase.txt", "keytao.phrase.dict.yaml", "keytao.phrase", "# 词组"),
    TableSpec("3.symbol.txt", "keytao.symbol.dict.yaml", "keytao.symbol", "# 符号"),
    TableSpec("4.supplement.txt", "keytao.supplement.dict.yaml", "keytao.supplement", "# 补充码表"),
    TableSpec("5.link.txt", "keytao.link.dict.yaml", "keytao.link", "# 链接等"),
    TableSpec("6.english.txt", "keytao.english.dict.yaml", "keytao.english", "# 英文词库"),
    TableSpec("7.css.txt", "keytao.css.dict.yaml", "keytao.css", "# 525声笔笔词组"),
)

# Entries this repo adds on top of upstream, appended in order. They go through
# the same validation and the same per-key candidate count as upstream rows --
# a local addition must not be a way to smuggle in something that breaks the
# Zig build.
LOCAL_ADDITIONS: dict[str, tuple[tuple[str, str], ...]] = {
    "5.link.txt": (("https://github.com/hronro/ime-jd", "ojd"),),
}

# Mirrors of the hard limits in core/src/trie.zig. Kept as constants so a
# violation is reported here, against an upstream line number, instead of as
# error.EntryKeysTooLong against a blob offset.
MAX_CODE_LEN = 6  # trie.MAX_KEYS_LEN
CODE_RE = re.compile(r"[a-z;]{1,6}")  # trie.isValidKeyByte: a-z plus ';'
MAX_CANDIDATES_PER_KEY = 255  # node value_count is a u8
MAX_VALUES_TOTAL = 0x00FF_FFFF  # packed 24-bit root subtree count

# gen_trie skips any line whose first non-space byte is '#', with no escape, so
# these column names are the only front matter we can make sense of.
KNOWN_COLUMNS = frozenset({"text", "code", "weight", "stem"})
FRONT_MATTER_KEYS = frozenset({"name", "version", "sort", "columns"})

# Keys that mean the file is no longer self-contained. Reading it as one flat
# table would silently drop rows, which is worse than failing.
FATAL_FRONT_MATTER_KEYS = {
    "import_tables": "upstream now merges rows from other tables; this converter reads a single file and would silently drop them",
    "use_preset_vocabulary": "upstream now pulls in Rime's preset vocabulary, which is not in this file",
}

SCALAR_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$")
LIST_ITEM_RE = re.compile(r"^[ \t]+-[ \t]*(.+?)[ \t]*$")


class SyncError(Exception):
    """Anything that must stop the sync before a byte is written."""


@dataclass(frozen=True)
class Row:
    text: str
    code: str
    weight: float | None
    origin: str  # "keytao.link.dict.yaml:14" or "LOCAL_ADDITIONS[5.link.txt]"


@dataclass
class FileResult:
    spec: TableSpec
    version: str
    rows: list[Row]
    rendered: bytes = b""
    warnings: list[str] = field(default_factory=list)
    reordered: int = 0
    local_added: int = 0
    status: str = ""
    added: int = 0
    removed: int = 0


# ---- fetching ----


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last: Exception | None = None
    for attempt in range(RETRIES + 1):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
                body = response.read()
            break
        except urllib.error.HTTPError as exc:
            # A 404 means the mapping broke -- a rename upstream, or a bad ref.
            # Retrying just delays a failure that needs a human.
            if exc.code not in (429, 500, 502, 503, 504):
                raise SyncError(f"{url}: HTTP {exc.code} {exc.reason}") from exc
            last = exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last = exc
        if attempt == RETRIES:
            raise SyncError(f"{url}: {last}") from last
        time.sleep(RETRY_BACKOFF_S[min(attempt, len(RETRY_BACKOFF_S) - 1)])
    else:  # pragma: no cover - the loop always breaks or raises
        raise SyncError(f"{url}: {last}")

    if not body:
        raise SyncError(f"{url}: empty response")
    if body.lstrip()[:1] == b"<":
        raise SyncError(f"{url}: served HTML, not a Rime dictionary (error page?)")
    return body


# ---- parsing ----


def decode(spec: TableSpec, raw: bytes, warnings: list[str]) -> list[str]:
    if raw.startswith(b"\xef\xbb\xbf"):
        warnings.append(f"{spec.upstream_name}: stripped a UTF-8 BOM")
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SyncError(f"{spec.upstream_name}: not valid UTF-8 at byte {exc.start}") from exc
    if "\r\n" in text:
        warnings.append(f"{spec.upstream_name}: normalized CRLF line endings")
        text = text.replace("\r\n", "\n")
    if "\r" in text:
        # A lone CR survives gen_trie's edge-trim only when it sits mid-line,
        # where it would land inside a committed candidate.
        raise SyncError(f"{spec.upstream_name}: contains a bare CR")
    return text.split("\n")


def split_document(spec: TableSpec, lines: list[str]) -> tuple[list[str], int]:
    """Return (front-matter block, index of the first data line)."""
    try:
        start = next(i for i, line in enumerate(lines) if line.rstrip() == "---")
    except StopIteration:
        raise SyncError(f"{spec.upstream_name}: no '---' marker; not a Rime dictionary") from None
    for i, line in enumerate(lines[:start]):
        if line.strip() and not line.lstrip().startswith("#"):
            raise SyncError(f"{spec.upstream_name}:{i + 1}: unexpected content before the '---' marker: {line!r}")

    end = None
    for i in range(start + 1, len(lines)):
        stripped = lines[i].rstrip()
        if stripped == "...":
            end = i
            break
        if stripped == "---":
            raise SyncError(f"{spec.upstream_name}:{i + 1}: multiple YAML documents; expected one header")
    if end is None:
        raise SyncError(f"{spec.upstream_name}: no '...' terminator; the Rime header is not closed")
    return lines[start + 1 : end], end + 1


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_front_matter(spec: TableSpec, block: list[str], offset: int) -> dict[str, object]:
    """A deliberately strict subset of YAML.

    Anything unrecognized is a hard error. That is the point: a real YAML
    parser would happily accept a restructured upstream file and hand back
    something that looks fine, which is exactly the failure this needs to
    catch. Being narrow is the feature.
    """
    values: dict[str, object] = {}
    list_key: str | None = None

    for i, line in enumerate(block):
        lineno = offset + i + 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue

        item = LIST_ITEM_RE.match(line)
        if item:
            if list_key is None:
                raise SyncError(f"{spec.upstream_name}:{lineno}: list item outside any key: {line!r}")
            values[list_key].append(_unquote(item.group(1)))  # type: ignore[union-attr]
            continue

        scalar = SCALAR_RE.match(line)
        if not scalar:
            raise SyncError(
                f"{spec.upstream_name}:{lineno}: unrecognized front-matter line: {line!r}"
                " -- upstream's header format changed; review before syncing"
            )

        key, rest = scalar.group(1), scalar.group(2).strip()
        if key in FATAL_FRONT_MATTER_KEYS:
            raise SyncError(f"{spec.upstream_name}:{lineno}: '{key}' -- {FATAL_FRONT_MATTER_KEYS[key]}")
        if key not in FRONT_MATTER_KEYS:
            raise SyncError(
                f"{spec.upstream_name}:{lineno}: unknown front-matter key '{key}'"
                " -- upstream's header format changed; review before syncing"
            )
        if key in values:
            raise SyncError(f"{spec.upstream_name}:{lineno}: duplicate front-matter key '{key}'")

        if rest == "":
            values[key] = []
            list_key = key
        elif rest.startswith("[") and rest.endswith("]"):
            values[key] = [_unquote(part.strip()) for part in rest[1:-1].split(",") if part.strip()]
            list_key = None
        else:
            values[key] = _unquote(rest)
            list_key = None

    for required in ("name", "version", "columns"):
        if required not in values:
            raise SyncError(f"{spec.upstream_name}: front matter has no '{required}'")
    if values["name"] != spec.dict_name:
        raise SyncError(
            f"{spec.upstream_name}: front matter says name '{values['name']}', expected '{spec.dict_name}'"
            " -- wrong file, or upstream renamed this dictionary"
        )
    if not str(values["version"]).strip():
        raise SyncError(f"{spec.upstream_name}: front matter has an empty 'version'")
    if not isinstance(values["columns"], list) or not values["columns"]:
        raise SyncError(f"{spec.upstream_name}: 'columns' is not a non-empty list")
    return values


def column_indices(spec: TableSpec, columns: list[str], warnings: list[str]) -> tuple[int, int, int | None]:
    """Return (text, code, weight) indices.

    Extracting by index makes a column *reorder* correct by construction, so
    that only earns a notice. A column we do not recognize is a different
    matter -- it could carry meaning we would drop -- so that is fatal.
    """
    unknown = [c for c in columns if c not in KNOWN_COLUMNS]
    if unknown:
        raise SyncError(
            f"{spec.upstream_name}: unknown column(s) {unknown} in {columns}"
            " -- upstream's format changed; review before syncing"
        )
    if len(set(columns)) != len(columns):
        raise SyncError(f"{spec.upstream_name}: duplicate column names in {columns}")
    for required in ("text", "code"):
        if required not in columns:
            raise SyncError(f"{spec.upstream_name}: no '{required}' column in {columns}")
    if tuple(columns) != ("text", "code", "weight"):
        warnings.append(f"{spec.upstream_name}: notice: columns are {columns}, not the usual ['text', 'code', 'weight']")
    weight_index = columns.index("weight") if "weight" in columns else None
    return columns.index("text"), columns.index("code"), weight_index


def extract_rows(
    spec: TableSpec,
    lines: list[str],
    data_start: int,
    text_i: int,
    code_i: int,
    weight_i: int | None,
    ncols: int,
    warnings: list[str],
) -> list[Row]:
    rows: list[Row] = []
    comments = 0
    short = 0
    need = max(text_i, code_i)

    for i, line in enumerate(lines[data_start:]):
        lineno = data_start + i + 1
        if not line.strip():
            continue
        fields = line.split("\t")

        if line.startswith("#"):
            # Tell a Rime comment apart from a real entry whose text starts
            # with '#'. The latter is unrepresentable: gen_trie would read the
            # whole line as a comment and there is no escape.
            if len(fields) > need and CODE_RE.fullmatch(fields[code_i]):
                raise SyncError(
                    f"{spec.upstream_name}:{lineno}: entry text starts with '#': {line!r}"
                    " -- gen_trie would treat the whole line as a comment and drop it"
                )
            comments += 1
            continue

        if len(fields) > ncols:
            raise SyncError(f"{spec.upstream_name}:{lineno}: {len(fields)} columns, expected at most {ncols}: {line!r}")
        if len(fields) <= need:
            raise SyncError(f"{spec.upstream_name}:{lineno}: only {len(fields)} column(s), need at least {need + 1}: {line!r}")
        if len(fields) < ncols:
            short += 1

        weight: float | None = None
        if weight_i is not None and len(fields) > weight_i:
            try:
                weight = float(fields[weight_i])
            except ValueError:
                warnings.append(f"{spec.upstream_name}:{lineno}: unparseable weight {fields[weight_i]!r}; leaving this row's order alone")

        # Verbatim, no strip. Preserving bytes is what keeps unchanged files
        # byte-identical and `git diff` honest -- two rows in 2.phrase.txt have
        # a trailing space that gen_trie trims at build time but that lives in
        # the file.
        rows.append(Row(fields[text_i], fields[code_i], weight, f"{spec.upstream_name}:{lineno}"))

    if not rows:
        raise SyncError(f"{spec.upstream_name}: no entries found (truncated download?)")
    if comments:
        warnings.append(f"{spec.upstream_name}: skipped {comments} comment line(s) in the data section")
    if short:
        warnings.append(f"{spec.upstream_name}: {short} row(s) had fewer than {ncols} columns")
    return rows


# ---- ordering, overlay, validation ----


def apply_order_guard(spec: TableSpec, rows: list[Row], warnings: list[str]) -> tuple[list[Row], int]:
    """Stable-sort each contiguous same-code run by ascending weight.

    Runs, not global groups: same-code rows are always adjacent upstream, and
    sorting only within a run means the file's overall code ordering cannot be
    disturbed. Never sort across files -- weights use a different base in each
    one, and cross-file priority belongs to core/build.zig.
    """
    out: list[Row] = []
    moved = 0
    i = 0
    while i < len(rows):
        j = i
        while j + 1 < len(rows) and rows[j + 1].code == rows[i].code:
            j += 1
        run = rows[i : j + 1]
        if len(run) > 1 and all(r.weight is not None for r in run):
            ordered = sorted(run, key=lambda r: r.weight)  # stable
            if [r.origin for r in ordered] != [r.origin for r in run]:
                moved += 1
                warnings.append(
                    f"{spec.upstream_name}: code {run[0].code!r} was not in ascending weight order upstream; reordered "
                    f"{[r.text for r in run]} -> {[r.text for r in ordered]}"
                )
                run = ordered
        out.extend(run)
        i = j + 1
    return out, moved


def apply_local_additions(spec: TableSpec, rows: list[Row], warnings: list[str]) -> tuple[list[Row], int]:
    additions = LOCAL_ADDITIONS.get(spec.local_name, ())
    if not additions:
        return rows, 0

    codes = {r.code for r in rows}
    pairs = {(r.text, r.code) for r in rows}
    out = list(rows)
    added = 0
    for text, code in additions:
        if (text, code) in pairs:
            warnings.append(f"{spec.local_name}: local addition {text!r} -> {code!r} now ships upstream; not adding it twice")
            continue
        if code in codes:
            warnings.append(f"{spec.local_name}: local addition {text!r} uses code {code!r}, which upstream also uses; it becomes an extra candidate")
        out.append(Row(text, code, None, f"LOCAL_ADDITIONS[{spec.local_name}]"))
        added += 1
    return out, added


def validate_rows(rows: list[Row]) -> None:
    for row in rows:
        where = row.origin
        if not row.code:
            # gen_trie skips these silently, which makes the loss invisible.
            raise SyncError(f"{where}: empty code -- gen_trie would skip this entry without a word")
        if len(row.code) > MAX_CODE_LEN:
            raise SyncError(f"{where}: code {row.code!r} is {len(row.code)} bytes, max {MAX_CODE_LEN} -- would be error.EntryKeysTooLong")
        if not CODE_RE.fullmatch(row.code):
            bad = next(c for c in row.code if not ("a" <= c <= "z" or c == ";"))
            raise SyncError(f"{where}: code {row.code!r} contains {bad!r}, outside the a-z ';' alphabet -- would be error.EntryKeyOutsideAlphabet")
        if not row.text.strip(" "):
            raise SyncError(f"{where}: empty text for code {row.code!r}")
        control = next((c for c in row.text if ord(c) < 0x20 or ord(c) == 0x7F), None)
        if control is not None:
            raise SyncError(f"{where}: text contains control character {control!r} -- it would land inside a candidate string")
        if row.text.lstrip(" ").startswith("#"):
            # lstrip matters: gen_trie trims leading spaces before its '#' test.
            raise SyncError(f"{where}: text {row.text!r} starts with '#' -- gen_trie would read the line as a comment")


def validate_corpus(results: list[FileResult]) -> tuple[str, int]:
    """Candidates accumulate per code across all seven files, so this check
    only means anything once every file is parsed."""
    counter: Counter[str] = Counter()
    per_file: dict[str, Counter[str]] = {}
    for result in results:
        codes = Counter(row.code for row in result.rows)
        per_file[result.spec.local_name] = codes
        counter.update(codes)

    code, count = counter.most_common(1)[0]
    if count > MAX_CANDIDATES_PER_KEY:
        breakdown = ", ".join(f"{name}: {c[code]}" for name, c in per_file.items() if c[code])
        raise SyncError(
            f"code {code!r} has {count} candidates, max {MAX_CANDIDATES_PER_KEY} ({breakdown})"
            " -- would be error.TooManyValuesPerNode"
        )
    total = sum(counter.values())
    if total > MAX_VALUES_TOTAL:
        raise SyncError(f"{total} entries exceeds the {MAX_VALUES_TOTAL} the blob's 24-bit count can hold")
    return code, count


# ---- rendering, comparison, writing ----


def render(spec: TableSpec, rows: list[Row]) -> bytes:
    body = "\n".join([spec.title, "", *(f"{row.text}\t{row.code}" for row in rows)]) + "\n"
    return body.encode("utf-8")


def compare(old: bytes | None, new: bytes) -> tuple[str, int, int]:
    if old is None:
        return "new", len(new.decode("utf-8").split("\n")) - 3, 0
    if old == new:
        return "unchanged", 0, 0
    old_rows = Counter(old.decode("utf-8").split("\n")[2:])
    new_rows = Counter(new.decode("utf-8").split("\n")[2:])
    return "updated", sum((new_rows - old_rows).values()), sum((old_rows - new_rows).values())


def write_table(path: Path, data: bytes) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    try:
        # Binary mode is not incidental: text mode would translate \n to \r\n
        # on Windows and quietly produce CRLF tables that gen_trie's default
        # -Dtables_eol=lf cannot parse.
        with open(tmp, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


# ---- driver ----


def build(spec: TableSpec, raw: bytes) -> FileResult:
    warnings: list[str] = []
    lines = decode(spec, raw, warnings)
    block, data_start = split_document(spec, lines)
    front = parse_front_matter(spec, block, data_start - len(block) - 1)
    text_i, code_i, weight_i = column_indices(spec, front["columns"], warnings)  # type: ignore[arg-type]
    ncols = len(front["columns"])  # type: ignore[arg-type]

    rows = extract_rows(spec, lines, data_start, text_i, code_i, weight_i, ncols, warnings)
    rows, reordered = apply_order_guard(spec, rows, warnings)
    rows, local_added = apply_local_additions(spec, rows, warnings)
    validate_rows(rows)

    result = FileResult(spec=spec, version=str(front["version"]), rows=rows, warnings=warnings)
    result.reordered = reordered
    result.local_added = local_added
    result.rendered = render(spec, rows)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Regenerate core/tables/*.txt from upstream KeyTao.")
    parser.add_argument("--check", action="store_true", help="write nothing; exit 1 if the tables are out of date")
    args = parser.parse_args()

    if not TABLES_DIR.is_dir():
        print(f"error: {TABLES_DIR} does not exist", file=sys.stderr)
        return 2

    try:
        # Phase 1: fetch everything before touching anything.
        raws = {spec.local_name: fetch(RAW_BASE + spec.upstream_name) for spec in TABLES}
        # Phase 2: parse and validate everything, including the cross-file check.
        results = [build(spec, raws[spec.local_name]) for spec in TABLES]
        hot_code, hot_count = validate_corpus(results)
    except SyncError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    # Phase 3: compare and report.
    for result in results:
        path = TABLES_DIR / result.spec.local_name
        current = path.read_bytes() if path.exists() else None
        result.status, result.added, result.removed = compare(current, result.rendered)

    for result in results:
        for warning in result.warnings:
            print(f"warning: {warning}", file=sys.stderr)

    print(f"upstream: {UPSTREAM_REPO} @ {UPSTREAM_REF}\n")
    print(f"{'file':<18}{'version':>12}{'rows':>9}{'+':>7}{'-':>7}   status")
    for result in results:
        note = f"   ({len(result.rows) - result.local_added} upstream +{result.local_added} local)" if result.local_added else ""
        print(
            f"{result.spec.local_name:<18}{result.version:>12}{len(result.rows):>9}"
            f"{result.added:>7}{result.removed:>7}   {result.status}{note}"
        )
    total = sum(len(r.rows) for r in results)
    reordered = sum(r.reordered for r in results)
    print(f"\n{total} entries; max candidates on one key: {hot_count} (code {hot_code!r}, limit {MAX_CANDIDATES_PER_KEY})")
    if reordered:
        print(f"{reordered} code group(s) were not in ascending weight order upstream and were reordered -- see warnings above")

    stale = [r for r in results if r.status != "unchanged"]
    if args.check:
        if stale:
            print(f"\nout of date: {', '.join(r.spec.local_name for r in stale)}")
            return 1
        print("\nup to date")
        return 0

    # Phase 4: write only what changed, so mtimes stay stable and Zig does not
    # rebuild the blob for nothing.
    for result in stale:
        write_table(TABLES_DIR / result.spec.local_name, result.rendered)
    if stale:
        print(f"\nwrote {len(stale)} file(s) to {TABLES_DIR}")
        print("next: cd core && zig build test --summary all")
    else:
        print("\nalready up to date; nothing written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
