#!/usr/bin/env python3
"""Download the test corpus: the plain text of 11 zh.wikipedia articles in
simplified Chinese (variant zh-cn), joined into <out_dir>/corpus.txt.

Usage: fetch_corpus.py <out_dir>

Wikipedia articles change, so a fresh download is close to, but not byte for
byte, the corpus behind benchmark.md (sha256 printed in benchmark/README.md).
The per-keystroke numbers barely depend on the exact text.
"""
import hashlib
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

# In this order (the order benchmark.md's corpus was joined in).
ARTICLES = ["中华人民共和国", "互联网", "人工智能", "北京市", "唐朝", "汉字", "熊猫", "经济学", "计算机", "输入法", "长江"]
API = "https://zh.wikipedia.org/w/api.php"
USER_AGENT = "jd-benchmark-corpus/1.0 (one-off download of 11 articles)"
PAUSE_S = 2  # between requests; the API rate-limits bursts


def fetch(title: str) -> str:
    query = urllib.parse.urlencode({
        "action": "query", "prop": "extracts", "explaintext": "1", "variant": "zh-cn",
        "format": "json", "redirects": "1", "titles": title,
    })
    req = urllib.request.Request(f"{API}?{query}", headers={"User-Agent": USER_AGENT})
    for attempt in range(5):
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
        try:
            pages = json.loads(body)["query"]["pages"]
        except (ValueError, KeyError):  # "You are making too many requests"
            time.sleep(10 * (attempt + 1))
            continue
        text = next(iter(pages.values())).get("extract", "")
        if not text:
            sys.exit(f"no text for {title}")
        return text
    sys.exit(f"gave up on {title}: still rate-limited")


out_dir = Path(sys.argv[1])
out_dir.mkdir(parents=True, exist_ok=True)
texts = []
for i, title in enumerate(ARTICLES):
    if i:
        time.sleep(PAUSE_S)
    t = fetch(title)
    print(f"{title}: {len(re.findall(r'[一-鿿]', t))} 汉字", flush=True)
    texts.append(t)
corpus = "\n".join(texts)
(out_dir / "corpus.txt").write_text(corpus, encoding="utf-8")
print(f"total {len(re.findall(r'[一-鿿]', corpus))} 汉字, sha256 {hashlib.sha256(corpus.encode()).hexdigest()}")
