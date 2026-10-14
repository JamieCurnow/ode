"""Whisper (whisper.cpp) and Deepgram engines for the bench. Prints JSON lines like the Swift engines.

    python3 -I engines.py whisper  <clips dir> <model.bin> [vocab.txt]
    python3 -I engines.py deepgram <clips dir> [vocab.txt]

With a vocab file, each engine also runs a second pass using it: Whisper gets the terms as its
initial prompt, Deepgram gets them as nova-3 keyterms.
"""

import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Whisper's prompt is capped at half its 448-token context; ~700 characters of terms stays under it.
WHISPER_PROMPT_CHARS = 700


def emit(clip, engine, text, ms):
    print(json.dumps({"id": clip.stem, "engine": engine, "text": text.strip(), "ms": ms}), flush=True)


def load_vocab(path):
    if not path:
        return []
    return [t.strip() for t in Path(path).read_text().splitlines() if t.strip()]


def whisper_once(clip, model, prompt=None):
    cmd = ["whisper-cli", "-m", model, "-f", str(clip), "-l", "en", "-nt"]
    if prompt:
        cmd += ["--prompt", prompt]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True)
    timings = dict(re.findall(r"whisper_print_timings:\s+(load|total) time =\s+([\d.]+) ms", out.stderr))
    # whisper-cli reloads the model on every run, so leave the load out to match a warm app.
    ms = int(float(timings.get("total", 0)) - float(timings.get("load", 0)))
    return " ".join(out.stdout.split()), ms


def run_whisper(clips, model, vocab):
    prompt = ""
    for term in vocab:
        if len(prompt) + len(term) + 2 > WHISPER_PROMPT_CHARS:
            break
        prompt = f"{prompt}, {term}" if prompt else term
    if vocab and len(prompt.split(", ")) < len(vocab):
        print(f"whisper: prompt holds {len(prompt.split(', '))} of {len(vocab)} vocabulary terms", file=sys.stderr)
    for clip in clips:
        text, ms = whisper_once(clip, model)
        emit(clip, "whisper-turbo", text, ms)
        if prompt:
            text, ms = whisper_once(clip, model, prompt)
            emit(clip, "whisper-turbo+vocab", text, ms)


def deepgram_key():
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "Ode Deepgram", "-a", "deepgram", "-w"],
        capture_output=True, text=True,
    )
    return out.stdout.strip() if out.returncode == 0 else None


def deepgram_once(clip, key, keyterms):
    params = [("model", "nova-3"), ("smart_format", "true"), ("language", "en")]
    params += [("keyterm", t) for t in keyterms]
    url = "https://api.deepgram.com/v1/listen?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(
        url, data=clip.read_bytes(), method="POST",
        headers={"Authorization": f"Token {key}", "Content-Type": "audio/wav"},
    )
    start = time.monotonic()
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = json.load(resp)
    ms = int((time.monotonic() - start) * 1000)
    return body["results"]["channels"][0]["alternatives"][0]["transcript"], ms


def run_deepgram(clips, vocab):
    key = deepgram_key()
    if not key:
        print('deepgram: skipped, no key in the Keychain (service "Ode Deepgram", account "deepgram")', file=sys.stderr)
        return
    # nova-3 takes up to 100 keyterms.
    keyterms = vocab[:100]
    try:
        # Warm the connection so the first clip's time isn't mostly TLS setup.
        deepgram_once(clips[0], key, [])
        for clip in clips:
            text, ms = deepgram_once(clip, key, [])
            emit(clip, "deepgram-nova3", text, ms)
            if keyterms:
                text, ms = deepgram_once(clip, key, keyterms)
                emit(clip, "deepgram-nova3+vocab", text, ms)
    except urllib.error.HTTPError as e:
        # The body explains bad keys, quota and bad params; it never echoes the key.
        print(f"deepgram: HTTP {e.code}: {e.read().decode(errors='replace')[:300]}", file=sys.stderr)
    except OSError as e:
        print(f"deepgram: request failed: {e}", file=sys.stderr)


def main():
    engine, clips_dir = sys.argv[1], Path(sys.argv[2])
    clips = sorted(clips_dir.glob("*.wav"))
    if not clips:
        sys.exit(f"no .wav clips in {clips_dir}")
    if engine == "whisper":
        run_whisper(clips, sys.argv[3], load_vocab(sys.argv[4] if len(sys.argv) > 4 else None))
    elif engine == "deepgram":
        run_deepgram(clips, load_vocab(sys.argv[3] if len(sys.argv) > 3 else None))
    else:
        sys.exit(f"unknown engine {engine}")


if __name__ == "__main__":
    main()
