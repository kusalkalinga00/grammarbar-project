#!/usr/bin/env python3
"""
Summarise an Eval/results/*.json run for RESULTS.md.

    python3 Eval/analyse.py Eval/results/apple-baseline-2026-10-13.json

Prints every number RESULTS.md quotes, so none of them are transcribed by hand.
Add --recon-baseline to also print the diff against PLAN-v2.md §0.3.
"""

import json
import re
import statistics
import sys
from collections import Counter, defaultdict

RECORDED = {  # PLAN-v2.md §0.3
    "errorsFixed": "10/12",
    "correctUnchanged": "6/6",
    "meanTtftMs": 362.0,
    "meanTotalMs": 435.0,
    "coldFirstMs": 971.0,
}


def wsnorm(s):
    return re.sub(r"\s+([.,;:!?])", r"\1", re.sub(r"\s+", " ", s)).strip()


def pctl(xs, p):
    xs = sorted(xs)
    if not xs:
        return 0.0
    rank = max(1, int(-(-(p / 100.0 * len(xs)) // 1)))
    return xs[min(rank, len(xs)) - 1]


def group(source):
    return source.split(" | ")[0]


def main():
    path = sys.argv[1]
    r = json.load(open(path))
    recs = r["records"]
    print(f"# {path}")
    print(f"cases={r['caseCount']}  mode={r['environment']['mode']}  "
          f"context={r['environment']['contextSize']}  avail={r['environment']['modelAvailability']}")
    print(f"cold first raw call: {r['coldFirstRawCallTtftMs']:.0f} ms "
          f"(PLAN §0.3 recorded {RECORDED['coldFirstMs']:.0f} ms)")

    # ---------------------------------------------------------------- PASSES
    for pname, get in (
        ("pipeline", lambda x: x),
        ("rawEngine", lambda x: x["rawPass"]),
    ):
        sel = [x for x in recs if get(x) is not None]
        def g(x, k):
            v = get(x)
            return v[k]
        wrong = [x for x in sel if x["kind"] == "wrong"]
        corr = [x for x in sel if x["kind"] == "correct"]
        fixed = [x for x in wrong if g(x, "fixed")]
        same = [x for x in corr if g(x, "byteIdenticalToInput")]
        ttft = [g(x, "ttftMs") for x in sel]
        lat = [g(x, "latencyMs") for x in sel]
        print(f"\n## {pname}")
        print(f"  errors fixed       {len(fixed)}/{len(wrong)}")
        print(f"  correct unchanged  {len(same)}/{len(corr)} = "
              f"{100.0*len(same)/max(len(corr),1):.1f}%")
        print(f"  TTFT   mean {statistics.fmean(ttft):.0f} p50 {pctl(ttft,50):.0f} p95 {pctl(ttft,95):.0f} ms")
        print(f"  total  mean {statistics.fmean(lat):.0f} p50 {pctl(lat,50):.0f} p95 {pctl(lat,95):.0f} ms")
        print(f"  tense flags {sum(1 for x in sel if g(x,'tenseFlagged'))}"
              f"  tenseChanges {sum(g(x,'tenseChanges') for x in sel)}"
              f"  cues {sum(g(x,'temporalCues') for x in sel)}")
        print(f"  delimiter echoes {sum(1 for x in sel if g(x,'delimiterEchoed'))}")
        print(f"  guardrail refusals {sum(1 for x in sel if g(x,'guardrailRefusal'))}")
        print(f"  validator rejected {sum(1 for x in sel if not g(x,'validatorAccepted'))}")
        print(f"  outcomes {dict(Counter(g(x,'outcome') for x in sel))}")
        print(f"  protected-token loss {sum(1 for x in sel if x['lostProtectedTokens'])}")

    # ---------------------------------------------------------- RECON SUBSET
    print("\n## recon 20-case subset vs PLAN-v2.md §0.3")
    recon = [x for x in recs if group(x["source"]) == "recon-apple-baseline"]
    for pname, get in (("pipeline", lambda x: x), ("rawEngine", lambda x: x["rawPass"])):
        w = [x for x in recon if x["kind"] == "wrong"]
        c = [x for x in recon if x["kind"] == "correct"]
        f = [x["id"] for x in w if get(x)["fixed"]]
        s = [x["id"] for x in c if get(x)["byteIdenticalToInput"]]
        tt = [get(x)["ttftMs"] for x in recon]
        to = [get(x)["latencyMs"] for x in recon]
        print(f"  {pname}: fixed {len(f)}/{len(w)} {f}")
        print(f"           unchanged {len(s)}/{len(c)} {s}")
        print(f"           meanTTFT {statistics.fmean(tt):.0f} ms   meanTotal {statistics.fmean(to):.0f} ms")
    miss = [x["id"] for x in recon if x["kind"] == "wrong" and not x["rawPass"]["fixed"]]
    print(f"  raw misses: {miss}")

    # ------------------------------------------- CORRECT-CASE DETAIL (why)
    print("\n## correct-kind cases that were edited")
    for pname, get in (("rawEngine", lambda x: x["rawPass"]),):
        edited = [x for x in recs if x["kind"] == "correct" and get(x)["output"] != x["input"]]
        bysrc = Counter(group(x["source"]) for x in edited)
        print(f"  {len(edited)} edited, by provenance {dict(bysrc)}")
        cosmetic = [x for x in edited
                    if wsnorm(get(x)["output"]) == wsnorm(x["input"])]
        print(f"  of those, whitespace/punctuation-normalisation only: {len(cosmetic)} "
              f"{[x['id'] for x in cosmetic]}")
        real = [x for x in edited if wsnorm(get(x)["output"]) != wsnorm(x["input"])]
        print(f"  substantive edits to already-correct text: {len(real)}")
        for x in real:
            print(f"    {x['id']} [{group(x['source'])}]")
            print(f"      in : {x['input']}")
            print(f"      out: {get(x)['output']}")
    # same, but restricted to first-party cases (recon + authored)
    fp = [x for x in recs if x["kind"] == "correct"
          and group(x["source"]) in ("recon-apple-baseline", "authored")]
    fps = [x for x in fp if x["rawPass"]["byteIdenticalToInput"]]
    print(f"  first-party correct (recon+authored): {len(fps)}/{len(fp)} unchanged")
    for pname, get in (("pipeline", lambda x: x),
                       ("rawEngine", lambda x: x["rawPass"])):
        cor = [x for x in recs if x["kind"] == "correct"]
        strict = sum(1 for x in cor if get(x)["byteIdenticalToInput"])
        norm = sum(1 for x in cor if wsnorm(get(x)["output"]) == wsnorm(x["input"]))
        print(f"  {pname}: strict {strict}/{len(cor)} = {100.0*strict/len(cor):.1f}% | "
              f"whitespace-normalised {norm}/{len(cor)} = {100.0*norm/len(cor):.1f}%")

    # ------------------------------------------------------------ BUG A / B
    print("\n## Bug A (TenseGuard) — what happened on cases the guard would fire on")
    flagged = [x for x in recs if x["rawPass"] and x["rawPass"]["tenseFlagged"]]
    print(f"  raw pass flagged {len(flagged)}/{len(recs)} cases")
    substituted = [x for x in flagged if x["outcome"] == "flagged"]
    corrected = [x for x in flagged if x["outcome"] == "corrected"]
    print(f"  pipeline substituted the original on {len(substituted)}: {[x['id'] for x in substituted]}")
    print(f"  pipeline still returned a correction on {len(corrected)} (minimal-edit retry "
          f"cleared the flag): {[x['id'] for x in corrected]}")
    silent = [x for x in flagged if x["outcome"] == "corrected"
              and x["tenseFlagged"]]
    print(f"  SILENTLY ACCEPTED tense mutation (guard failed): {len(silent)} {[x['id'] for x in silent]}")
    print(f"  pipeline retry-ladder uses (attempts>1): "
          f"{sum(1 for x in recs if x['attempts'] > 1)}")

    print("\n## Bug B (delimiter echo)")
    echo = [x for x in recs if x["rawPass"] and x["rawPass"]["delimiterEchoed"]]
    print(f"  raw echoes: {len(echo)} {[x['id'] for x in echo]}")
    print(f"  pipeline escalations to another delimiter: "
          f"{sum(1 for x in recs if x['delimiterEscalated'])}")
    print(f"  s2 (injection) outcome: "
          f"{[ (x['id'], x['outcome'], x['output']==x['input'], x['warnings']) for x in recs if x['id']=='s2']}")

    # ------------------------------------------------------------- FAILURES
    print("\n## failures")
    fail = [x for x in recs if x["outcome"] == "failed"]
    print(f"  pipeline failed {len(fail)}/{len(recs)}")
    print(f"  by provenance {dict(Counter(group(x['source']) for x in fail))}")
    print(f"  errors {dict(Counter(x['error'] for x in fail))}")
    print(f"  guardrail-attributed {sum(1 for x in fail if x['guardrailRefusal'])}")

    # ---------------------------------------------------------- MEANING
    print("\n## meaning-changed / over-edit")
    print(f"  meaningChangedCases {r['meaningChangedCases']}")
    print(f"  overEditedCorrectCases {r['overEditedCorrectCases']}")
    mm = [x for x in recs if x["meaningChanged"]]
    for x in mm:
        print(f"    {x['id']}: tense {x['tenseChanges']} cues {x['temporalCues']} lost {x['lostProtectedTokens']}")
        print(f"      in : {x['input']}")
        print(f"      out: {x['output']}")

    print("\n## per-kind, per-provenance fixed/unchanged (rawEngine)")
    agg = defaultdict(lambda: [0, 0])
    for x in recs:
        g_ = group(x["source"])
        if x["kind"] == "wrong":
            agg[(g_, "wrong")][1] += 1
            agg[(g_, "wrong")][0] += 1 if x["rawPass"]["fixed"] else 0
        elif x["kind"] == "correct":
            agg[(g_, "correct")][1] += 1
            agg[(g_, "correct")][0] += 1 if x["rawPass"]["byteIdenticalToInput"] else 0
    for (g_, k), (num, den) in sorted(agg.items()):
        print(f"  {g_:22s} {k:8s} {num}/{den}")


if __name__ == "__main__":
    main()
