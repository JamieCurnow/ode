"""Scores every engine's transcripts against prompts.txt and writes a Markdown report.

    python3 -I score.py <prompts.txt> <vocab.txt> <results dir>

Reads every *.jsonl in the results dir (lines of {"id", "engine", "text", "ms"}; anything else on a
line, like Core ML warnings, is ignored) and writes report.md next to them.

- WER: word error rate after lowercasing, dropping punctuation and fillers (um, uh…), and spelling
  numbers out ("401" → "four oh one", "20" → "twenty"), so formatting choices don't count as errors.
- Key terms: vocabulary words and names in the reference, checked in the output. "Exact" needs the
  right spelling and capitals ("HYOS", "ClickUp"); "any case" ignores capitals and spacing.
- Time: per clip, warm (model already loaded). Deepgram's includes the network round trip.
"""

import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

FILLERS = {"um", "uh", "erm", "er", "ah", "hmm", "mm"}
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
SAME = {"yeah": "yea", "ok": "okay"}


def number_words(digits):
    n = int(digits)
    if len(digits) >= 3:  # codes like 401 are said digit by digit
        return " ".join("oh" if d == "0" else ONES[int(d)] for d in digits)
    if n < 20:
        return ONES[n]
    return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])


def normalise(text):
    # Apple's dictation acts on spoken commands; count those as the words that were said.
    text = text.replace("\n\n", " new paragraph ").replace("\n", " new line ").replace("•", " bullet point ")
    text = text.lower()
    text = re.sub(r"(\d+)(st|nd|rd|th)\b", r"\1", text)
    text = re.sub(r"\d+", lambda m: " " + number_words(m.group()) + " ", text)
    text = re.sub(r"[.\-/]", " ", text)  # Marker.io, sign-up, and/or
    text = re.sub(r"[^\w\s']", " ", text)
    words = [SAME.get(w, w) for w in text.replace("'", "").split()]
    return [w for w in words if w not in FILLERS]


def wer(ref, hyp):
    r, h = normalise(ref), normalise(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)], len(r)


def terms_in(reference, vocab):
    found = [t for t in vocab if re.search(r"(?<!\w)" + re.escape(t) + r"(?!\w)", reference)]
    # "Claude Code" covers "Claude": only count the longest match at each spot.
    return [t for t in found if not any(t != o and t in o and o in found for o in found)]


def has_term(text, term, exact):
    if exact:
        return re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text) is not None
    squash = lambda s: re.sub(r"[^a-z0-9]", "", s.lower())
    return squash(term) in squash(text)


def main():
    prompts, vocab_file, results = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    refs = {}
    for line in prompts.read_text().splitlines():
        if line.strip() and not line.startswith("#") and "|" in line:
            cid, text = line.split("|", 1)
            refs[cid.strip()] = text.strip()
    vocab = [t.strip() for t in vocab_file.read_text().splitlines() if t.strip()]

    rows = defaultdict(dict)  # engine -> id -> row
    for f in sorted(results.glob("*.jsonl")):
        for line in f.read_text().splitlines():
            m = re.search(r"\{.*\}", line)
            if not m:
                continue
            try:
                row = json.loads(m.group())
            except json.JSONDecodeError:
                continue
            if row.get("id") in refs:
                rows[row["engine"]][row["id"]] = row

    order = ["apple", "apple+vocab", "parakeet-v2", "parakeet-v2+vocab", "parakeet-ultra",
             "whisper-turbo", "whisper-turbo+vocab", "deepgram-nova3", "deepgram-nova3+vocab"]
    engines = [e for e in order if e in rows] + sorted(e for e in rows if e not in order)
    ids = [i for i in refs if any(i in rows[e] for e in engines)]

    summary = []
    for e in engines:
        errs = words = hit_exact = hit_any = total_terms = 0
        times = []
        for i in ids:
            if i not in rows[e]:
                continue
            hyp = rows[e][i]["text"]
            de, n = wer(refs[i], hyp)
            errs, words = errs + de, words + n
            for t in terms_in(refs[i], vocab):
                total_terms += 1
                hit_exact += has_term(hyp, t, exact=True)
                hit_any += has_term(hyp, t, exact=False)
            times.append(rows[e][i]["ms"])
        summary.append((e, errs / max(words, 1), hit_exact, hit_any, total_terms,
                        statistics.median(times) if times else 0, max(times) if times else 0, len(times)))

    out = ["# Transcription bench", ""]
    out.append(f"{len(ids)} clips. Lower WER is better. Times are warm, per clip.")
    out.append("")
    out.append("| Engine | WER | Key terms exact | Key terms, any case | Median time | Slowest | Clips |")
    out.append("|---|---|---|---|---|---|---|")
    for e, w, he, ha, tt, med, mx, n in summary:
        out.append(f"| {e} | {w:.1%} | {he}/{tt} | {ha}/{tt} | {med:.0f} ms | {mx} ms | {n} |")
    out.append("")
    out.append("WER ignores case, punctuation and fillers, and spells out numbers. Key terms are the "
               "vocabulary words and names in each reference; \"exact\" needs the right spelling and capitals.")
    out.append("")
    for i in ids:
        out.append(f"## {i}")
        out.append("")
        out.append(f"**Reference:** {refs[i]}")
        terms = terms_in(refs[i], vocab)
        if terms:
            out.append("")
            out.append(f"Key terms: {', '.join(terms)}")
        out.append("")
        out.append("| Engine | Output | Errors | Missed terms |")
        out.append("|---|---|---|---|")
        for e in engines:
            if i not in rows[e]:
                continue
            hyp = rows[e][i]["text"]
            de, n = wer(refs[i], hyp)
            missed = [t for t in terms if not has_term(hyp, t, exact=True)]
            cell = hyp.replace("|", "\\|").replace("\n", " ⏎ ") or "_(nothing)_"
            out.append(f"| {e} | {cell} | {de}/{n} | {', '.join(missed)} |")
        out.append("")
    (results / "report.md").write_text("\n".join(out))
    for e, w, he, ha, tt, med, mx, n in summary:
        print(f"{e:22} WER {w:6.1%}  terms {he:2}/{tt} exact, {ha:2}/{tt} any case  median {med:5.0f} ms")
    print(f"Report: {results / 'report.md'}")


if __name__ == "__main__":
    main()
