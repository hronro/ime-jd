#!/usr/bin/env python3
"""Summarize work/out/*.json as markdown tables on stdout (and work/out/data.json).

Usage: report.py
"""
import json
import statistics
from pathlib import Path

OUT = Path(__file__).resolve().parent / "work" / "out"
ENGINES = ("libjd", "rime-core", "rime-scheme-gcdefault", "rime-scheme-sbboff", "rime-scheme")


def load(n):
    p = OUT / f"{n}.json"
    return json.loads(p.read_text()) if p.exists() else None


def t(ns):
    if ns is None:
        return "—"
    if ns < 1000:
        return f"{ns:.0f} ns"
    if ns < 1_000_000:
        return f"{ns / 1e3:.1f} µs"
    if ns < 1_000_000_000:
        return f"{ns / 1e6:.2f} ms"
    return f"{ns / 1e9:.2f} s"


def mib(b):
    return f"{b / 1048576:.1f} MiB"


data = {}

print("## Keystrokes\n")
print("`stream` = the whole corpus, `slice` = its first keys (the as-shipped scheme only runs on a slice).")
print("Per keystroke, mean of untimed passes; percentiles from timed passes; × libjd = same kind and stream.\n")
print("| config | run | events | output ok | engine only | with page read | × libjd | p50 | p90 | p99 | p99.9 | max |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for kind in ("stream", "slice"):
    for e in ENGINES:
        for s in ("space", "topup"):
            d = load(f"{kind}_{e}_{s}")
            if not d:
                continue
            tp = d["throughput_ns_per_event"]
            lat = d["latency_ns"]["with_reads"]
            row = dict(events=d["events"], ok=d["output_ok"], eng=statistics.median(tp["engine_only"]),
                       reads=statistics.median(tp["with_reads"]), lat=lat,
                       cats={k: v for k, v in d["latency_ns"].items() if k not in ("engine_only", "with_reads")})
            data[f"{kind}_{e}_{s}"] = row
            base = data.get(f"{kind}_libjd_{s}")
            ratio = f"{row['reads'] / base['reads']:,.0f}×" if base else "—"
            print(f"| {e} | {kind}:{s} | {d['events']} | {d['output_ok']} | {t(row['eng'])} | {t(row['reads'])} | {ratio} | "
                  f"{t(lat['p50'])} | {t(lat['p90'])} | {t(lat['p99'])} | {t(lat['p999'])} | {t(lat['max'])} |")

print("\n## Keystrokes by kind (slice; topup_key from the topup stream, the rest from space), p50 / p99\n")
cats = ["first_key", "next_key", "topup_key", "space", "select", "punct"]
print("| config | " + " | ".join(cats) + " |")
print("|---|" + "---|" * len(cats))
for e in ENGINES:
    cells = []
    for c in cats:
        d = data.get(f"slice_{e}_{'topup' if c == 'topup_key' else 'space'}")
        v = d and d["cats"].get(c)
        cells.append(f"{t(v['p50'])} / {t(v['p99'])}" if v else "—")
    if any(c != "—" for c in cells):
        print(f"| {e} | " + " | ".join(cells) + " |")

print("\n## Startup (page cache warm, median)\n")
print("| config | runs | process wall | engine ready | first key | first commit | private memory after first key | max RSS |")
print("|---|---|---|---|---|---|---|---|")
for e in ("libjd", "rime-scheme", "rime-scheme-gcdefault", "rime-core"):
    runs = load(f"startup_{e}")
    if not runs:
        continue
    med = lambda f: statistics.median(f(r) for r in runs)
    phases = {k: med(lambda r, k=k: r["startup_ns"][k]) for k in runs[0]["startup_ns"]}
    row = dict(wall=med(lambda r: r["process_wall_ns"]), phases=phases, first_key=med(lambda r: r["first_key_ns"]),
               first_commit=med(lambda r: r["first_commit_ns"]),
               fp=med(lambda r: r["mem_after_first_key"]["footprint"] - r["mem_before_init"]["footprint"]),
               rss=med(lambda r: r["max_rss"]))
    data[f"startup_{e}"] = row
    print(f"| {e} | {len(runs)} | {t(row['wall'])} | {t(phases['total'])} | {t(row['first_key'])} | "
          f"{t(row['first_commit'])} | {row['fp'] / 1024:.0f} KiB | {mib(row['rss'])} |")
    print("|  ↳ phases | | " + ", ".join(f"{k} {t(v)}" for k, v in phases.items() if k != "total") + " | | | | | |")

print("\n## More sessions\n")
for e in ("libjd", "rime-scheme", "rime-core"):
    d = load(f"sessions_{e}")
    if not d:
        continue
    data[f"sessions_{e}"] = d
    c = d["create_ns"]["create"]
    print(f"- {e}: create p50 {t(c['p50'])} (max {t(c['max'])}); per session: footprint "
          f"{d['per_session_footprint'] / 1024:.0f} KiB, heap {d['per_session_heap'] / 1024:.1f} KiB, "
          f"{d['per_session_mallocs']:.0f} mallocs; destroy {t(d['destroy_ns_mean'])}")

print("\n## Allocations per keystroke (space stream, with page reads)\n")
for e in ("libjd", "rime-core", "rime-scheme-gcdefault", "rime-scheme"):
    d = load(f"allocs_{e}")
    if not d:
        continue
    a = d.get("allocs_per_event") or {}
    data[f"allocs_{e}"] = dict(per_event=a, startup=d["startup_allocs"], events=d["events"],
                               footprint_delta=d["mem_after_all"]["footprint"] - d["mem_before_init"]["footprint"],
                               resident=d["resident_after_all"])
    print(f"- {e} ({d['events']} keys): {a.get('mallocs', 0):.1f} mallocs, {a.get('bytes', 0) / 1000:.1f} KB; "
          f"startup {d['startup_allocs']['mallocs']} mallocs; process resident after the run {mib(d['resident_after_all'])}")

print("\n## Building the dictionary\n")
g = load("gen_trie")
if g:
    data["gen_trie"] = dict(median=statistics.median(g["wall_ns"]), outputs=g["outputs"])
    print(f"- libjd gen_trie, at build time: {t(statistics.median(g['wall_ns']))}; outputs {g['outputs']}")
for n in ("deploy_main_schema", "deploy_all_schemas"):
    runs = load(n)
    if not runs:
        continue
    m = statistics.median(r["startup_ns"]["maintenance"] for r in runs)
    rss = statistics.median(r["max_rss"] for r in runs)
    data[n] = dict(median=m, max_rss=rss, build_bytes=runs[0]["build_bytes"])
    print(f"- Rime {n}: {t(m)}, max RSS {mib(rss)}, writes {mib(runs[0]['build_bytes'])}")

print("\n## Applying an edited user dictionary (median)\n")
print("libjd: read the file, jd_user_dict_build, jd_init, release the old context. Rime: 重新部署 as Squirrel does it")
print("(finalize, initialize, start_maintenance(full check)) and a new session. Both then type the edited phrase.\n")
print("| phrases | libjd apply | of which build | libjd cached start | Rime, all schemas | Rime, main schema | × libjd (all / main) | peak RSS libjd / Rime |")
print("|---|---|---|---|---|---|---|---|")
for n in (1, 100, 1000, 10000, 100000, 500000):
    j = load(f"userdict_libjd_{n}")
    ra = load(f"userdict_rime-all_schemas_{n}")
    rm = load(f"userdict_rime-main_schema_{n}")
    if not (j and ra and rm):
        continue
    ju, au, mu = j["userdict"], ra["userdict"], rm["userdict"]
    if not (ju["ok"] and au["ok"] and mu["ok"]):
        print(f"| {n} | probe phrase NOT typable after the edit | | | | | | |")
        continue
    ja = ju["apply_total"]["median"]
    cached = ju["cached_check"]["median"] + ju["cached_init"]["median"]
    a, m = au["apply_total"]["median"], mu["apply_total"]["median"]
    data[f"userdict_{n}"] = dict(libjd=ja, libjd_build=ju["build"]["median"], libjd_cached=cached, rime_all=a, rime_main=m,
                                 rime_first_use=au["first_use"]["median"], libjd_first_use=ju["first_use"]["median"],
                                 rss_libjd=j["max_rss"], rss_rime=max(ra["max_rss"], rm["max_rss"]))
    print(f"| {n} | {t(ja)} | {t(ju['build']['median'])} | {t(cached)} | {t(a)} | {t(m)} | {a / ja:,.0f}× / {m / ja:,.0f}× | "
          f"{mib(j['max_rss'])} / {mib(max(ra['max_rss'], rm['max_rss']))} |")

(OUT / "data.json").write_text(json.dumps(data, indent=1))
