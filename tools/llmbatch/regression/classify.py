import json, os, sys, re

def load_jsonl(p):
    out={}
    if not os.path.exists(p): return out
    for line in open(p, encoding="utf-8"):
        line=line.strip()
        if not line: continue
        o=json.loads(line); out[o["id"]]=o
    return out

meta = load_jsonl("/tmp/koe-corpus-meta.jsonl")
dict_entries = [l.strip() for l in open(os.path.expanduser("~/.koe/dictionary.txt"), encoding="utf-8")
                if l.strip() and not l.startswith("#")]

def is_cjk(c): return '一' <= c <= '鿿'
def norm(s): return re.sub(r'\s+','', s.lower())

def classify(asr, out):
    if out is None: return "error"
    o, a = out.strip(), asr.strip()
    if o == "": return "empty"
    ol, al = o.lower(), a.lower()
    # dump
    leaked = sum(1 for e in dict_entries if e.lower() in ol and e.lower() not in al)
    if leaked >= 8: return "dump"
    # translation: asr substantially CJK but output has zero CJK
    asr_cjk = sum(1 for c in a if is_cjk(c))
    out_cjk = sum(1 for c in o if is_cjk(c))
    if asr_cjk >= 6 and out_cjk == 0: return "translation"
    # collapse: output is a verbatim fragment of asr, dropped >= half
    on, an = norm(o).rstrip('。.，,！!？?'), norm(a)
    oc, ac = len(on), len(an)
    dropped = max(0, ac-oc)
    if oc>0 and on in an and oc*2 <= ac and dropped>=8: return "collapse"
    # severe truncation
    if oc>0 and oc*3 <= ac and ac>=18 and dropped>=12: return "truncation"
    return "ok"

arms = {
    "A_no_llm": None,  # baseline = asr itself
    "B_0.6b": load_jsonl("/tmp/koe-results-0.6b.jsonl"),
    "C_1.7b": load_jsonl("/tmp/koe-results-1.7b.jsonl"),
}

cats = ["ok","dump","collapse","truncation","translation","empty","error"]
print(f"{'arm':<10} " + " ".join(f"{c:>11}" for c in cats) + "   degrade%")
rows_detail = {}
for arm, res in arms.items():
    counts = {c:0 for c in cats}
    detail = []
    for i, m in meta.items():
        asr = m["asr_text"]
        out = asr if res is None else (res.get(i,{}).get("output"))
        cat = "ok" if res is None else classify(asr, out)
        counts[cat]+=1
        if cat not in ("ok",): detail.append((i, m["source"], cat, asr, out))
    n=len(meta)
    degrade = sum(counts[c] for c in ["dump","collapse","truncation","translation","empty","error"])
    pct = 100.0*degrade/n if n else 0
    print(f"{arm:<10} " + " ".join(f"{counts[c]:>11}" for c in cats) + f"   {pct:5.1f}%")
    rows_detail[arm]=detail

# dump per-arm degenerate examples
for arm, detail in rows_detail.items():
    if not detail: continue
    print(f"\n=== {arm} degenerate samples ({len(detail)}) ===")
    for i,src,cat,asr,out in detail[:30]:
        print(f"[{cat}|{src}] in:  {asr[:60]}")
        print(f"          out: {('<None>' if out is None else out[:60])}")
