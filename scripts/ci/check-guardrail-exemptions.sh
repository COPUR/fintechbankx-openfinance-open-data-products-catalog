#!/usr/bin/env bash
# Self-test for this repository's .github/guardrail-exemptions.txt, run with the secret scan step from the workflow.
# Every entry needs a file, the exact line and a reason, and the line must still be in that file (a stale entry fails).
# In a throwaway tree, each listed line passes in its own file only: the same line under another path is reported,
# and a literal value added to a listed file is reported.
# Usage: bash scripts/ci/check-guardrail-exemptions.sh <publication-guardrails.yml>
# The key name below is built from parts, so this file does not contain the literal shape it tests.
set -euo pipefail

wf=${1:?usage: check-guardrail-exemptions.sh <publication-guardrails.yml>}
list=.github/guardrail-exemptions.txt
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
PW=pass'word'

awk -v job="  secret-pattern-scan:" -v step="Scan secret-like patterns" '
  $0 == job { in_job = 1; next }
  in_job && /^  [a-z]/ { exit }
  in_job && $0 == "      - name: " step { in_step = 1; next }
  in_step && /^      - name:/ { exit }
  in_step && /^        run: \|$/ { in_run = 1; next }
  in_run { sub(/^          /, ""); print }
' "$wf" > "$work/secret.sh"
[ -s "$work/secret.sh" ] || { echo "the secret scan step was not found in $wf"; exit 1; }
[ -f "$list" ] || { echo "no $list: nothing to check"; exit 0; }

tree="$work/tree"
mkdir -p "$tree/.github"
cp "$list" "$tree/$list"
n=0
files=()
while IFS= read -r entry; do
  case $entry in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r file text reason extra <<<"$entry"
  if [ -z "${file:-}" ] || [ -z "${text:-}" ] || [ -z "${reason:-}" ] || [ -n "${extra:-}" ]; then
    echo "FAIL malformed entry (file, TAB, exact line, TAB, reason): $entry"; fail=1; continue
  fi
  if ! grep -qxF -- "$text" "$file" 2>/dev/null; then
    echo "FAIL stale entry: the listed line is no longer in $file"; fail=1; continue
  fi
  n=$((n + 1))
  mkdir -p "$tree/$(dirname "$file")" "$tree/copy$n/$(dirname "$file")"
  printf '%s\n' "$text" >> "$tree/$file"
  printf '%s\n' "$text" > "$tree/copy$n/$file"
  files+=("$file")
done < "$list"

mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -u)
for file in "${files[@]}"; do
  [ -n "$file" ] && printf '%s: hunter2\n' "$PW" >> "$tree/$file"
done

out="$work/out"
(cd "$tree" && bash -eo pipefail "$work/secret.sh" > "$out" 2>&1) || true

for file in "${files[@]}"; do
  [ -n "$file" ] || continue
  last=$(wc -l < "$tree/$file")
  if ! grep -q "^\./$file:$last:" "$out"; then echo "FAIL a literal value added to $file was not reported"; fail=1; fi
  if grep "^\./$file:" "$out" | grep -vq "^\./$file:$last:"; then echo "FAIL a listed line in $file was reported"; fail=1; fi
done
for ((i = 1; i <= n; i++)); do
  if ! grep -q "^\./copy$i/" "$out"; then echo "FAIL listed line $i passed under another path (copy$i/)"; fail=1; fi
done

[ "$fail" -eq 0 ] && echo "exemptions checked: $n listed line(s), each exempt in its own file only"
exit "$fail"
