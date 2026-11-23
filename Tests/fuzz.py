#!/usr/bin/env python3
"""Damages each given file in several ways and runs the tool on the result.
A crash (killed by a signal) or a hang counts as a failure; reporting "unsupported" does not.
Usage: fuzz.py <tool> <rounds> <files...>"""
import os, random, subprocess, sys, tempfile

tool, rounds, samples = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
random.seed(20261123)
bad = 0
work = tempfile.mkdtemp(prefix="nakami-fuzz-")
for path in samples:
    src = open(path, "rb").read()
    if len(src) < 8:
        continue
    name = os.path.basename(path)
    out = os.path.join(work, name)
    for i in range(rounds):
        b = bytearray(src)
        mode = i % 4
        if mode == 0:        # a few bytes near the start (headers)
            for _ in range(random.randint(1, 8)):
                b[random.randrange(min(len(b), 4096))] = random.randrange(256)
        elif mode == 1:      # bytes anywhere
            for _ in range(random.randint(1, 40)):
                b[random.randrange(len(b))] = random.randrange(256)
        elif mode == 2:      # cut short
            b = b[:random.randrange(1, len(b))]
        else:                # a block of 0xFF, zeros or noise
            at = random.randrange(len(b)); n = random.randint(4, 4096)
            fill = random.choice([b"\xff", b"\x00", None])
            b[at:at + n] = (fill * n if fill else os.urandom(n))[:max(0, min(n, len(b) - at))]
        with open(out, "wb") as f:
            f.write(b)
        try:
            rc = subprocess.run([tool, out], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20).returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
        if rc == "timeout" or rc < 0:
            bad += 1
            keep = os.path.join(work, "crash-%d-%s" % (i, name))
            os.replace(out, keep)
            print("FAIL %s round %d (%s): kept as %s" % (name, i, rc, keep))
    if os.path.exists(out):
        os.remove(out)
print("damaged files: %d failure(s) in %d runs" % (bad, rounds * len(samples)))
sys.exit(1 if bad else 0)
