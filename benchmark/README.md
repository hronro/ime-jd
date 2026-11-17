# Benchmark: libjd vs the Rime-based 键道 scheme

The harness behind [benchmark.md](../benchmark.md). It types the same keystrokes into libjd and into librime running the [Rime-based 键道 scheme](https://github.com/xkinput/KeyTao) (基于 Rime 实现的键道输入方案), checks that both commit the same text, and measures what each costs per keystroke, at startup, in memory and to build its dictionary.

macOS only: the harness reads memory through Mach and counts allocations by dyld interposing.

## Running it

Requirements: macOS, Zig (the version `core/` needs), the Xcode command line tools, `git`, `curl` and `python3`.

```sh
benchmark/setup.sh                    # downloads, builds, deploys; a few minutes
python3 benchmark/run_all.py --quick  # smoke test, about a minute
python3 benchmark/run_all.py          # the full suite, about 25 minutes
python3 benchmark/report.py           # markdown tables from work/out/
```

Everything generated goes to `benchmark/work/`, which git ignores. `run_all.py` also takes step names to run only some of the steps: `gentrie deploy startup sessions streams allocs userdict`. Run nothing else heavy while it measures.

## What `setup.sh` prepares

| | |
|---|---|
| librime | the official 1.17.0 macOS release (`rime-33e7814-macOS-universal.tar.bz2`, sha256-checked), with the librime-lua plugin |
| the scheme | commit `d3cece2` of its repository: `rime/` plus the desktop schema `schema/desktop/`, untouched |
| shared data | [rime-prelude](https://github.com/rime/rime-prelude) at `082425e` |
| libjd | `zig build -Doptimize=fast`, as the macOS app builds it, linked statically |
| corpus | 11 zh.wikipedia articles in simplified Chinese, from `fetch_corpus.py` |

It deploys three Rime user directories, the configurations `run_all.py` compares:

| config | user directory | what it is |
|---|---|---|
| `rime-scheme` | `user-scheme` | the scheme as shipped: its Lua processors, translators and filters, switches at their defaults |
| `rime-scheme-sbboff` | `user-scheme` | the same, with the scheme's 630-hint switch turned off through `set_option` |
| `rime-scheme-gcdefault` | `user-scheme-gcdefault` | as shipped, minus `collectgarbage("setpause", 50)` and `collectgarbage("setstepmul", 400)` in `rime.lua` |
| `rime-core` | `user-core` | a `keytao.custom.yaml` patch removes every `lua_*` component: librime itself on the same dictionaries, without 顶功 |

## The keystroke streams

`gen_streams.py` segments the corpus against `core/tables/*.txt` — the same rows as the scheme's dictionaries — taking the longest word that has a code on which it can be picked from the first page, and writes two streams:

- `space`: every word is its code, then space, or a digit to pick it from the page.
- `topup`: 顶功 — the space is left out wherever both engines commit on the next word's first key.

Words the two engines would type differently stay out: `o`-initial codes, where the scheme's Lua translator adds date and time candidates; codes containing `;`; and the four English codes the scheme's Lua topup rule commits partway through, such as `gllgle` (Google), which it commits after `gllg`. Digits, Latin letters and the punctuation the two map differently (`、`, `《》`, …) are skipped.

Each run first replays its stream and compares the committed text with the expected text byte for byte; a mismatch fails the run.

The corpus behind benchmark.md had sha256 `1f94260a98cf5230a6eb231fd786baadced7c061b6b1230893e32bdc6d504483` (152,871 汉字; 383,711 keys in the `space` stream, 330,997 in `topup`). Wikipedia articles change, so a fresh download differs a little; to reuse a corpus, put it at `work/corpus/corpus.txt` before running `setup.sh`.

## What each keystroke costs

Each engine gets what a front end does on a key press, without any UI:

- libjd (`harness/bench_jd.c`): `jd_press_key`, the commit from the state block, then `jd_read_range` for the first 6 candidates. Picking candidate *i* is `jd_set_anchor(i)` plus space.
- librime (`harness/bench_rime.c`): `process_key`, then `get_commit`, `get_status` and `get_context` with its 6-candidate page — the calls Squirrel makes on every key. Picking a candidate is its digit key. Logging is at WARNING.

`harness/common.h` runs each stream as one verified pass, then untimed passes (mean cost, with and without the reads), then timed passes (percentiles, split by kind of key). The clock ticks every 41.7 ns, which is about libjd's whole per-key cost, so libjd's percentiles sit at the clock's resolution; the means come from the untimed passes. The as-shipped scheme costs about 2 ms per key, so it runs on the first 50,000 keys (`slice` in the results); libjd also runs on that slice, so the ratios compare identical keys.

Allocations are counted by `harness/allocc.c`, which interposes `malloc`, `calloc`, `realloc`, `free` and the zone variants. libjd allocates one region per context outside `malloc` (Zig's `smp_allocator`), visible as a 16 KiB footprint per context.

## Applying a user-dictionary edit

Both engines read user phrases in the same `value<TAB>keys` line format, but apply an edit differently. The `userdict` step measures both at 1, 100, 1,000 and 10,000 phrases (libjd's limit), with random 2–4-character phrases on 键道-shaped codes (`userdict_inputs` in `run_all.py`):

- libjd (`eng_userdict` in `harness/bench_jd.c`): what a front end does when the user saves — read the file, `jd_user_dict_build` into a buffer, `jd_init` on the blob, release the old context. Afterwards it also times a later start with that blob cached: `jd_user_dict_check` plus `jd_init`.
- Rime (`eng_userdict` in `harness/bench_rime.c`): the scheme's user dictionary is `keytao.user.dict.yaml`, compiled into its dictionaries, so an edit takes effect through 重新部署. The harness does what Squirrel's `deploy()` does — `finalize`, `initialize`, `start_maintenance` with a full check — waits for the deploy, and opens a new session. It runs with the three schemas the scheme enables by default, and again with the main schema alone.

Each repetition appends a new probe phrase on a code neither engine has built in (untimed: the user's edit), applies it, then types the probe's code and space; the run fails unless that commits the probe phrase. The scheme's other user-phrase path, a `custom_phrase` translator reading `user_dict.txt`, is not measured.

## Not covered

A cold disk cache (that needs `sudo purge`), phones and other slow devices, Windows and Linux, and drawing the candidate window.
