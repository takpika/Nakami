#!/bin/sh
# Builds the command-line tool straight from the sources, generates the fixtures, and checks the reports.
# Then feeds damaged copies of every fixture to the tool: none may crash or hang.
# Usage: Tests/run.sh [rounds of damage per fixture, default 40]
set -e
cd "$(dirname "$0")/.."
ROUNDS="${1:-40}"
B=Tests/.build
mkdir -p "$B"
echo "== building"
swiftc -swift-version 5 -O -lbz2 -o "$B/nakami" Core/*.swift UI/*.swift CLI/main.swift
echo "== generating fixtures"
python3 Tests/make-fixtures.py Tests/fixtures >/dev/null
echo "== checking reports"
fail=0
while IFS="$(printf '\t')" read -r file want; do
  case "$file" in ''|\#*) continue ;; esac
  out="$B/$file.txt"
  [ -f "$out" ] || NAKAMI_LANG=en "$B/nakami" "Tests/fixtures/$file" > "$out" 2>/dev/null || { echo "FAIL $file: the tool exited with an error"; fail=1; continue; }
  if grep -qF -- "$want" "$out"; then :; else echo "FAIL $file: missing \"$want\""; fail=1; fi
done < Tests/expect.tsv
rm -f "$B"/*.txt
[ "$fail" = 0 ] && echo "reports ok"
echo "== damaged files ($ROUNDS rounds each)"
python3 Tests/fuzz.py "$B/nakami" "$ROUNDS" Tests/fixtures/* Tests/fixtures/._classic || fail=1
exit $fail
