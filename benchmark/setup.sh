#!/bin/sh
# Prepare everything run_all.py needs, under benchmark/work/ (macOS only):
#   1. librime (official macOS release, with the librime-lua plugin)
#   2. the Rime-based 键道 scheme and rime-prelude, at pinned commits
#   3. the corpus (11 zh.wikipedia articles), unless work/corpus/corpus.txt exists
#   4. libjd (zig build -Doptimize=fast, as the macOS app builds it)
#   5. the harness binaries
#   6. the Rime data directories, deployed
#   7. the keystroke streams
# Re-running skips downloads that are already in place and redoes the rest.

set -eu

BENCH=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$BENCH")
WORK="$BENCH/work"

LIBRIME_TAG=1.17.0
LIBRIME_ASSET=rime-33e7814-macOS-universal.tar.bz2
LIBRIME_SHA256=11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850
SCHEME_URL=https://github.com/xkinput/KeyTao.git
SCHEME_COMMIT=07efecdd6ea3368783b499f8a15f9ff12c0bf245
PRELUDE_URL=https://github.com/rime/rime-prelude.git
PRELUDE_COMMIT=082425ea0684bca36474415d4a0e8db9b016487e
MIN_MACOS=12.0

if [ "$(uname -s)" != Darwin ]; then
    echo "error: the harness is macOS only" >&2
    exit 1
fi
for tool in zig cc git curl python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on PATH" >&2; exit 1; }
done

DEPS="$WORK/deps"
BIN="$WORK/bin"
RIME="$WORK/rime"
mkdir -p "$DEPS" "$BIN" "$RIME/log"

echo "== librime $LIBRIME_TAG"
LIBRIME="$DEPS/librime"
if [ ! -f "$LIBRIME/dist/lib/librime.1.dylib" ]; then
    rm -rf "$LIBRIME"
    mkdir -p "$LIBRIME"
    curl -fsSL -o "$LIBRIME/$LIBRIME_ASSET" \
        "https://github.com/rime/librime/releases/download/$LIBRIME_TAG/$LIBRIME_ASSET"
    echo "$LIBRIME_SHA256  $LIBRIME/$LIBRIME_ASSET" | shasum -a 256 -c - >/dev/null
    tar -xjf "$LIBRIME/$LIBRIME_ASSET" -C "$LIBRIME"
fi

checkout() {  # dir url commit
    if [ "$(git -C "$1" rev-parse HEAD 2>/dev/null || true)" != "$3" ]; then
        rm -rf "$1"
        git init -q "$1"
        git -C "$1" fetch -q --depth 1 "$2" "$3"
        git -C "$1" checkout -q FETCH_HEAD
    fi
}
echo "== Rime scheme ${SCHEME_COMMIT%"${SCHEME_COMMIT#???????}"}, rime-prelude ${PRELUDE_COMMIT%"${PRELUDE_COMMIT#???????}"}"
checkout "$DEPS/scheme" "$SCHEME_URL" "$SCHEME_COMMIT"
checkout "$DEPS/rime-prelude" "$PRELUDE_URL" "$PRELUDE_COMMIT"

echo "== corpus"
if [ ! -f "$WORK/corpus/corpus.txt" ]; then
    python3 -I "$BENCH/fetch_corpus.py" "$WORK/corpus"
fi

echo "== libjd"
case "$(uname -m)" in
    arm64) ZIG_TARGET="aarch64-macos.$MIN_MACOS" ;;
    x86_64) ZIG_TARGET="x86_64-macos.$MIN_MACOS" ;;
    *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
(cd "$REPO/core" && zig build -Doptimize=fast -Dtarget="$ZIG_TARGET" --prefix "$WORK/libjd")

echo "== harness"
R="$LIBRIME/dist"
CFLAGS="-O2 -Wall -mmacosx-version-min=$MIN_MACOS"
# shellcheck disable=SC2086
cc $CFLAGS -I "$REPO/core/include" "$BENCH/harness/bench_jd.c" "$WORK/libjd/lib/libjd.a" -o "$BIN/bench_jd"
# shellcheck disable=SC2086
cc $CFLAGS -I "$R/include" "$BENCH/harness/bench_rime.c" -L "$R/lib" -lrime -Wl,-rpath,"$R/lib" -o "$BIN/bench_rime"
# shellcheck disable=SC2086
cc $CFLAGS -dynamiclib "$BENCH/harness/allocc.c" -o "$BIN/allocc.dylib"

echo "== Rime data"
rm -rf "$RIME/shared"
mkdir -p "$RIME/shared"
cp "$DEPS/rime-prelude/"*.yaml "$RIME/shared/"

deploy() {  # user_dir: the first start deploys it
    RIME_SHARED="$RIME/shared" RIME_USER="$1" RIME_LOG="$RIME/log" "$BIN/bench_rime" startup >/dev/null 2>&1
}
scheme_files() {  # dest: the scheme as installed on a desktop
    rm -rf "$1"
    mkdir -p "$1"
    cp -R "$DEPS/scheme/rime/." "$1/"
    cp "$DEPS/scheme/schema/desktop/"*.yaml "$1/"
}

# The scheme as shipped.
scheme_files "$RIME/user-scheme"
deploy "$RIME/user-scheme"

# As shipped, minus the two lines in rime.lua that retune Lua's GC.
rm -rf "$RIME/user-scheme-gcdefault"
cp -R "$RIME/user-scheme" "$RIME/user-scheme-gcdefault"
sed -i '' '/collectgarbage("setpause", 50)/d; /collectgarbage("setstepmul", 400)/d' "$RIME/user-scheme-gcdefault/rime.lua"
if grep -q 'collectgarbage("set' "$RIME/user-scheme-gcdefault/rime.lua"; then
    echo "error: rime.lua's GC lines changed upstream; update setup.sh" >&2
    exit 1
fi

# librime alone: the same dictionaries with every lua_* component removed.
scheme_files "$RIME/user-core"
cat > "$RIME/user-core/keytao.custom.yaml" <<'EOF'
patch:
  engine/processors: [ascii_composer, recognizer, key_binder, speller, punctuator, selector, navigator, express_editor]
  engine/translators: [punct_translator, table_translator, "history_translator@repeat_history", "table_translator@custom_phrase"]
  engine/filters: ["simplifier@emoji_cn", "simplifier@simplification", uniquifier, "reverse_lookup_filter@danzi_lookup"]
EOF
deploy "$RIME/user-core"

echo "== streams"
python3 -I "$BENCH/gen_streams.py" "$REPO/core/tables" "$WORK/corpus/corpus.txt" "$WORK/streams"

echo "done. next: python3 benchmark/run_all.py   (or --quick for a smoke test)"
