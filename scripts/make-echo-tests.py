#!/usr/bin/env python3
"""Builds test recordings for microphone cleaning: what Dabber would record on a call without headphones.

For each scenario it writes, at 48 kHz:
  mac.wav    - Mac audio track (stereo): the other side of the call;
  mic.wav    - microphone track (mono): you + the other side again from the speakers through the room + noise;
  near.wav   - what a perfect cleaner would leave: only you, as the mic hears you, no echo, no noise;
  meta.json  - parameters and the timeline of who talks when.

Speech is LibriSpeech (CC BY 4.0, 16 kHz, so nothing above 8 kHz): 73 utterances of one reader (9 MB), downloaded
on the first run. "Them" is the same reader shifted up in pitch. The rooms and speakers are simulated.

Usage: scripts/make-echo-tests.py [out_dir]       (default build/echo-tests)
Needs: pip3 install numpy scipy soundfile pyarrow
"""
import io
import json
import sys
import urllib.request
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf
from scipy import signal

SPEECH_URL = (
    "https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy/resolve/main/"
    "clean/validation-00000-of-00001.parquet"
)
RATE = 48_000
rng = np.random.default_rng(7)


def load_utterances(path):
    table = pq.read_table(path).to_pydict()
    out = []
    for a in table["audio"]:
        x, sr = sf.read(io.BytesIO(a["bytes"]), dtype="float32")
        out.append(signal.resample_poly(x, RATE // sr, 1).astype(np.float32))
    return out


def take_speech(utts, seconds, start_index, pitch=1.0):
    """Concatenates utterances (short pauses between) to `seconds`; pitch > 1 makes a different, higher voice."""
    need = int(seconds * RATE)
    parts, total, i = [], 0, start_index
    while total < need:
        u = utts[i % len(utts)]
        if pitch != 1.0:
            up, down = 100, int(round(100 * pitch))
            u = signal.resample_poly(u, up, down).astype(np.float32)
        gap = np.zeros(int(rng.uniform(0.2, 0.5) * RATE), np.float32)
        parts += [u, gap]
        total += len(u) + len(gap)
        i += 1
    # Speech stops a little before the segment ends, so the echo tail does not spill into the next one.
    x = np.concatenate(parts)[: need - int(0.8 * RATE)]
    fade = np.linspace(0, 1, 480, dtype=np.float32)
    x[:480] *= fade
    x[-480:] *= fade[::-1]
    return np.concatenate([x, np.zeros(need - len(x), np.float32)])


def rms(x):
    return float(np.sqrt(np.mean(x.astype(np.float64) ** 2) + 1e-20))


def room_response(rt60, distance_ms, direct_gain=1.0, length_s=None):
    """Direct sound after `distance_ms`, a few early reflections, then an exponentially decaying noise tail
    whose high frequencies die faster."""
    length_s = length_s or min(1.5 * rt60 + 0.05, 1.2)
    n = int(length_s * RATE)
    h = np.zeros(n, np.float32)
    d = int(distance_ms * RATE / 1000)
    h[d] = direct_gain
    for _ in range(8):
        k = d + int(rng.uniform(2, 25) * RATE / 1000)
        h[k] += rng.uniform(-0.5, 0.5) * direct_gain
    t = np.arange(n) / RATE
    tail_start = d + int(0.005 * RATE)
    decay = np.exp(-6.9 * t / rt60)
    lows = signal.sosfilt(signal.butter(2, 2000, "low", fs=RATE, output="sos"), rng.standard_normal(n))
    highs = signal.sosfilt(signal.butter(2, 2000, "high", fs=RATE, output="sos"), rng.standard_normal(n))
    tail = lows * decay + highs * decay ** 2
    tail[:tail_start] = 0
    h += (0.25 * direct_gain * tail / max(np.abs(tail).max(), 1e-9)).astype(np.float32)
    return h


def laptop_speaker(x, drive):
    """Small speakers: little bass, some resonance, soft clipping when loud."""
    x = signal.sosfilt(signal.butter(2, 250, "high", fs=RATE, output="sos"), x)
    b, a = signal.iirpeak(3500, 2, fs=RATE)
    x = x + 0.3 * signal.lfilter(b, a, x)
    return (np.tanh(drive * x) / np.tanh(drive)).astype(np.float32)


def background(n, kind, level_db):
    if kind == "none":
        return np.zeros(n, np.float32)
    white = rng.standard_normal(n)
    # Fan: pink-ish broadband plus a hum and a blade tone.
    pink = signal.lfilter([0.049922035, -0.095993537, 0.050612699, -0.004408786], [1, -2.494956002, 2.017265875, -0.522189400], white)
    t = np.arange(n) / RATE
    x = pink / rms(pink) + 0.3 * np.sin(2 * np.pi * 50 * t) + 0.1 * np.sin(2 * np.pi * 120 * t + 1)
    return (x / rms(x) * 10 ** (level_db / 20)).astype(np.float32)


# Who talks when, seconds: (start, end, who) with who in {"them", "me", "both", "none"}.
TIMELINE = [
    (0, 10, "them"),     # far end only: the mic must end up silent here
    (10, 18, "me"),      # near end only: must stay as it is
    (18, 28, "both"),    # double talk: keep me, drop them
    (28, 36, "them"),    # far end only again, after double talk (has the filter survived?)
    (36, 40, "none"),    # nobody: only room noise
    (40, 48, "me"),
]

SCENARIOS = {
    # MacBook speakers at a normal level in a small furnished room, quiet.
    "laptop-normal": dict(echo_db=-6, rt60=0.30, delay_ms=45, drive=1.5, noise="fan", noise_db=-50),
    # Loud speakers, bare echoey room, echo louder than you, audible fan.
    "loud-echoey": dict(echo_db=+6, rt60=0.65, delay_ms=70, drive=3.0, noise="fan", noise_db=-42),
    # Headphones: no echo at all, only noise. Cleaning must not hurt the voice.
    "headphones": dict(echo_db=None, rt60=0.30, delay_ms=0, drive=1.0, noise="fan", noise_db=-48),
}


def build(utts, name, p, out):
    total = TIMELINE[-1][1]
    n = total * RATE
    them = np.zeros(n, np.float32)
    me = np.zeros(n, np.float32)
    for k, (a, b, who) in enumerate(TIMELINE):
        s, e = a * RATE, b * RATE
        if who in ("them", "both"):
            them[s:e] = take_speech(utts, b - a, 7 * k, pitch=1.25)
        if who in ("me", "both"):
            me[s:e] = take_speech(utts, b - a, 7 * k + 40)
    speech_rms = 10 ** (-26 / 20)
    them *= speech_rms / rms(them[them != 0])
    me *= speech_rms / rms(me[me != 0])

    # You, about 40 cm from the mic: mostly direct sound.
    near = signal.fftconvolve(me, room_response(p["rt60"], 1.2, length_s=0.4))[:n].astype(np.float32)
    near *= speech_rms / rms(near[me != 0])
    mic = near.copy()
    echo = np.zeros(n, np.float32)
    if p["echo_db"] is not None:
        played = laptop_speaker(them / np.abs(them).max(), p["drive"])
        echo = signal.fftconvolve(played, room_response(p["rt60"], p["delay_ms"]))[:n].astype(np.float32)
        active = them != 0
        echo *= speech_rms * 10 ** (p["echo_db"] / 20) / rms(echo[active])
        mic += echo
    mic += background(n, p["noise"], p["noise_db"])
    peak = max(np.abs(mic).max(), 1e-9)
    if peak > 0.9:
        scale = 0.9 / peak
        mic *= scale
        near *= scale
    d = out / name
    d.mkdir(parents=True, exist_ok=True)
    sf.write(d / "mac.wav", np.stack([them, them], 1), RATE, subtype="FLOAT")
    sf.write(d / "mic.wav", mic, RATE, subtype="FLOAT")
    sf.write(d / "near.wav", near, RATE, subtype="FLOAT")
    meta = dict(scenario=name, rate=RATE, **p, timeline=[dict(start=a, end=b, who=w) for a, b, w in TIMELINE])
    (d / "meta.json").write_text(json.dumps(meta, indent=2))
    erl = 20 * np.log10(rms(echo[them != 0]) / speech_rms) if p["echo_db"] is not None else None
    print(f"{name}: echo vs you {erl if erl is None else round(erl, 1)} dB, mic peak {peak:.2f}")


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "build" / "echo-tests")
    out.mkdir(parents=True, exist_ok=True)
    speech = out / "librispeech.parquet"
    if not speech.exists():
        print(f"downloading speech to {speech}")
        urllib.request.urlretrieve(SPEECH_URL, speech)
    utts = load_utterances(speech)
    for name, p in SCENARIOS.items():
        build(utts, name, p, out)


if __name__ == "__main__":
    main()
