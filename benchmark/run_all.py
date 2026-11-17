#!/usr/bin/env python3
"""Run the libjd vs librime measurements one after another; JSON to work/out/.

Usage: run_all.py [--quick] [step ...]
  steps: gentrie deploy startup sessions streams allocs userdict   (default: all)
  --quick   tiny slices and few repetitions, to check the pipeline (~1 min)

Run benchmark/setup.sh first. The full suite takes about 25 minutes, most of
it the as-shipped scheme, which costs ~2 ms per keystroke.
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

BENCH = Path(__file__).resolve().parent
REPO = BENCH.parent
WORK = BENCH / "work"
BIN = WORK / "bin"
T = WORK / "streams"
OUT = WORK / "out"
RIME = WORK / "rime"

# Configurations. "rime-*" all run the scheme's dictionaries on librime:
#   rime-scheme            the scheme as shipped (Lua processors, translators, filters)
#   rime-scheme-sbboff     as shipped, with the scheme's 630-hint switch off
#   rime-scheme-gcdefault  as shipped, minus the two GC-tuning lines in rime.lua
#   rime-core              no lua_* components at all: librime itself (no 顶功)
ENGINES = {
    "libjd": ("bench_jd", {}),
    "rime-scheme": ("bench_rime", {"RIME_USER": "user-scheme"}),
    "rime-scheme-sbboff": ("bench_rime", {"RIME_USER": "user-scheme", "RIME_OPTS": "sbb_hint=0"}),
    "rime-scheme-gcdefault": ("bench_rime", {"RIME_USER": "user-scheme-gcdefault"}),
    "rime-core": ("bench_rime", {"RIME_USER": "user-core"}),
}


def run(engine, args, extra_env=None, allocc=False):
    exe, env_add = ENGINES[engine]
    env = dict(os.environ, RIME_SHARED=str(RIME / "shared"), RIME_LOG=str(RIME / "log"))
    for k, v in env_add.items():
        env[k] = str(RIME / v) if k == "RIME_USER" else v
    env.update(extra_env or {})
    if allocc:
        env["DYLD_INSERT_LIBRARIES"] = str(BIN / "allocc.dylib")
    t0 = time.perf_counter_ns()
    p = subprocess.run([str(BIN / exe), *args], env=env, capture_output=True, text=True, cwd=str(RIME))
    wall = time.perf_counter_ns() - t0
    if p.returncode != 0 or not p.stdout.strip().startswith("{"):
        sys.exit(f"{engine} {' '.join(args)} failed ({p.returncode}):\n{p.stderr[-2000:]}\n{p.stdout[-2000:]}")
    d = json.loads(p.stdout)
    d["process_wall_ns"] = wall
    return d


def save(name, data):
    (OUT / f"{name}.json").write_text(json.dumps(data, indent=1, ensure_ascii=False))
    print(f"  -> {name}", flush=True)


def stream(engine, s, tput, lat, allocc=False, limit=0):
    return run(engine, ["stream", str(T / f"{s}.keys"), str(T / f"{s}.expect"), str(T / f"{s}.cats"),
                        str(tput), str(lat), str(limit)], allocc=allocc)


def deploy(n, schema_list=None):
    """Fresh copies of the as-shipped scheme, timing the first start (= the deploy)."""
    out = []
    for _ in range(n):
        dst = RIME / "deploy-tmp"
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(RIME / "user-scheme", dst,
                        ignore=shutil.ignore_patterns("build", "*.userdb", "user.yaml", "installation.yaml"))
        if schema_list:
            (dst / "default.custom.yaml").write_text(
                "patch:\n  schema_list:\n" + "".join(f"    - schema: {s}\n" for s in schema_list)
                + "  menu:\n    page_size: 6\n")
        d = run("rime-scheme", ["startup"], {"RIME_USER": str(dst)})
        d["build_bytes"] = sum(f.stat().st_size for f in (dst / "build").iterdir())
        out.append(d)
    shutil.rmtree(RIME / "deploy-tmp", ignore_errors=True)
    return out


def gen_trie(n):
    """libjd's build-time dictionary compiler, on the same tables."""
    exes = sorted((REPO / "core" / ".zig-cache").rglob("gen_trie"), key=lambda p: p.stat().st_mtime)
    if not exes:
        sys.exit("gen_trie not found: run benchmark/setup.sh first")
    tables = sorted(str(p) for p in (REPO / "core" / "tables").glob("*.txt"))
    tmp = WORK / "gen-trie-out"
    res = []
    for _ in range(n):
        shutil.rmtree(tmp, ignore_errors=True)
        tmp.mkdir()
        t0 = time.perf_counter_ns()
        subprocess.run([str(exes[-1]), str(tmp), "lf", "le", *tables], check=True, capture_output=True)
        res.append(time.perf_counter_ns() - t0)
    outputs = {p.name: p.stat().st_size for p in tmp.iterdir()}
    shutil.rmtree(tmp)
    return {"wall_ns": res, "outputs": outputs}


TOPUP = set("avuio;")  # the scheme's topup keys, as in gen_streams.py
CONSONANTS = "bcdefghjklmnpqrstwxyz"


def userdict_inputs(n_total):
    """Phrase sets for the userdict step: n_total - 1 random phrases (the
    harness appends the probe phrase as the n_total-th), and a probe code that
    neither engine has built in, so typing it commits the probe phrase only if
    the edit took effect."""
    import random
    rows = []
    for f in sorted((REPO / "core" / "tables").glob("*.txt")):
        for line in f.read_text(encoding="utf-8").split("\n"):
            s = line.strip(" \r")
            if s and not s.startswith("#") and "\t" in s:
                v, k = s.split("\t", 1)
                rows.append((v.strip(), k.strip()))
    prefixes = {k[:i] for _, k in rows for i in range(1, len(k) + 1)}
    probe = next(a + b + c + d for a in CONSONANTS for b in CONSONANTS for c in "aiouv" for d in "aiouv"
                 if a + b + c + d not in prefixes)
    chars = list(dict.fromkeys(v for v, _ in rows if len(v) == 1 and "一" <= v <= "鿿"))[:3000]
    rng = random.Random(n_total)
    phrases = []
    while len(phrases) < n_total - 1:
        code = rng.choice(CONSONANTS) + rng.choice(CONSONANTS) + "".join(rng.choice("aiouv") for _ in range(rng.randint(1, 4)))
        if code.startswith(probe[:3]) or probe.startswith(code):
            continue
        phrases.append(("".join(rng.choice(chars) for _ in range(rng.randint(2, 4))), code))
    return probe, "".join(f"{v}\t{k}\n" for v, k in phrases)


def userdict(quick):
    sizes = (1, 1000) if quick else (1, 100, 1000, 10000)
    jd_reps, rime_reps = (3, 1) if quick else (20, 3)
    header = (RIME / "user-scheme" / "keytao.user.dict.yaml").read_text(encoding="utf-8-sig")
    tmp = WORK / "userdict"
    tmp.mkdir(exist_ok=True)
    for n in sizes:
        probe, body = userdict_inputs(n)
        (tmp / "base.txt").write_text(body, encoding="utf-8")
        d = run("libjd", ["userdict", str(tmp / "phrases.txt"), str(tmp / "base.txt"), str(jd_reps), probe, "探针"])
        save(f"userdict_libjd_{n}", d)
        (tmp / "base.yaml").write_text(header.rstrip("\n") + "\n" + body, encoding="utf-8")
        for label, schema_list in (("all_schemas", None), ("main_schema", ["keytao"])):
            dst = RIME / "userdict-tmp"
            shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(RIME / "user-scheme", dst)  # deployed, as before the edit
            if schema_list:
                (dst / "default.custom.yaml").write_text(
                    "patch:\n  schema_list:\n" + "".join(f"    - schema: {s}\n" for s in schema_list)
                    + "  menu:\n    page_size: 6\n")
            # Start from a deployed state that already holds the n-1 phrases.
            shutil.copy(tmp / "base.yaml", dst / "keytao.user.dict.yaml")
            run("rime-scheme", ["startup"], {"RIME_USER": str(dst)})
            d = run("rime-scheme", ["userdict", str(dst / "keytao.user.dict.yaml"), str(tmp / "base.yaml"),
                                    str(rime_reps), probe, "探针"], {"RIME_USER": str(dst)})
            d["build_bytes"] = sum(f.stat().st_size for f in (dst / "build").iterdir())
            save(f"userdict_rime-{label}_{n}", d)
    shutil.rmtree(RIME / "userdict-tmp", ignore_errors=True)


def main():
    argv = sys.argv[1:]
    quick = "--quick" in argv
    steps = [a for a in argv if a != "--quick"] or ["gentrie", "deploy", "startup", "sessions", "streams", "allocs", "userdict"]
    if not (BIN / "bench_rime").exists() or not (T / "space.keys").exists():
        sys.exit("run benchmark/setup.sh first")
    OUT.mkdir(parents=True, exist_ok=True)

    # The as-shipped scheme runs on a slice of the streams: ~2 ms per key
    # makes the full 383k-key stream over four passes take ~50 minutes.
    slice_ = 2000 if quick else 50000
    full = slice_ if quick else 0
    reps = 3 if quick else 20
    tput, lat = (1, 1) if quick else (5, 3)

    if "gentrie" in steps:
        print("gen_trie", flush=True)
        save("gen_trie", gen_trie(2 if quick else 5))
    if "deploy" in steps:
        print("deploy", flush=True)
        save("deploy_main_schema", deploy(1 if quick else 3, ["keytao"]))
        save("deploy_all_schemas", deploy(1 if quick else 3))
    if "startup" in steps:
        print("startup", flush=True)
        for e in ("libjd", "rime-scheme", "rime-scheme-gcdefault", "rime-core"):
            run(e, ["startup"])  # warm the page cache
            save(f"startup_{e}", [run(e, ["startup"]) for _ in range(reps)])
    if "sessions" in steps:
        print("sessions", flush=True)
        for e in ("libjd", "rime-scheme", "rime-core"):
            save(f"sessions_{e}", run(e, ["sessions", "4" if quick else "16"], allocc=True))
    if "streams" in steps:
        print("streams", flush=True)
        for st in ("space", "topup"):
            save(f"stream_libjd_{st}", stream("libjd", st, tput, lat, limit=full))
            save(f"slice_libjd_{st}", stream("libjd", st, tput, lat, limit=slice_))
            save(f"stream_rime-scheme-gcdefault_{st}", stream("rime-scheme-gcdefault", st, 1, 1, limit=full))
            save(f"slice_rime-scheme-gcdefault_{st}", stream("rime-scheme-gcdefault", st, 1, 1, limit=slice_))
        # No Lua means no 顶功 processor: the space stream only.
        save("stream_rime-core_space", stream("rime-core", "space", 3 if not quick else 1, 2 if not quick else 1, limit=full))
        save("slice_rime-core_space", stream("rime-core", "space", 3 if not quick else 1, 2 if not quick else 1, limit=slice_))
        for st in ("space", "topup"):
            save(f"slice_rime-scheme_{st}", stream("rime-scheme", st, 1, 1, limit=slice_))
        save("slice_rime-scheme-sbboff_space", stream("rime-scheme-sbboff", "space", 1, 1, limit=slice_))
    if "allocs" in steps:
        print("allocs", flush=True)
        save("allocs_libjd", stream("libjd", "space", 1, 0, allocc=True, limit=full))
        save("allocs_rime-core", stream("rime-core", "space", 1, 0, allocc=True, limit=full))
        save("allocs_rime-scheme-gcdefault", stream("rime-scheme-gcdefault", "space", 1, 0, allocc=True, limit=slice_))
        save("allocs_rime-scheme", stream("rime-scheme", "space", 1, 0, allocc=True, limit=min(slice_, 20000)))
    if "userdict" in steps:
        print("userdict", flush=True)
        userdict(quick)
    print(f"done. results in {OUT}; summary: python3 benchmark/report.py", flush=True)


if __name__ == "__main__":
    main()
