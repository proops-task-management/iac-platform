#!/usr/bin/env bash
# ===========================================================================
# lint-brace-guard.sh — the one TSG-028 check shellcheck CANNOT do.
#
# THE DEFECT. `log "resolving $PUBLIC_IP…"` — an unbraced expansion immediately
# followed by U+2026 — aborted cluster-up.sh mid-window with
# `PUBLIC_IP\xe2: unbound variable`. Bash scans the identifier BYTE-wise, so the
# leading 0xE2 of the 3-byte ellipsis is absorbed into the variable name, producing
# a name that was never set; `set -u` then kills the run.
#
# WHY SHELLCHECK DOES NOT CATCH IT. shellcheck parses the file as UNICODE TEXT: it
# sees `$PUBLIC_IP` followed by one `…` character and reports nothing. Verified
# directly against shellcheck 0.10.0 with the offending line — clean pass (MIN-60
# AC-4). The bug lives exactly in the gap between the two models, so the check has
# to be done on BYTES, which is what this script does.
#
# WHY THIS EXISTS AT ALL INSTEAD OF A LINE IN IRD-014. MIN-60's whole subject is
# that a safeguard living somewhere nothing forces it to run is not a safeguard
# (MIN-58's rule in a code comment; actionlint in a local hook with no CI twin).
# Closing that issue by writing the brace rule into a document would have repeated
# the defect in the act of fixing it. The rule gets an enforcer.
#
# ONE FILE, TWO CALLERS. The `brace-guard` pre-commit hook and the `script-lint` CI
# job both exec THIS script, so local and CI cannot drift — lockstep is structural,
# not a pair of version pins someone has to remember to bump together.
#
# Usage: ./scripts/lint-brace-guard.sh [FILE ...]
#        (no args -> every tracked *.sh). Read-only, $0, no AWS. Exit 1 on any hit.
# ===========================================================================
set -euo pipefail

usage() {
  cat <<'EOF'
lint-brace-guard.sh [FILE ...]

Fails when a shell file contains an unbraced $VAR immediately followed by a
non-ASCII byte -- the TSG-028 pattern that shellcheck cannot see.

  bad:   echo "resolving $PUBLIC_IP..."      (with a real ellipsis, U+2026)
  good:  echo "resolving ${PUBLIC_IP}..."

With no arguments, checks every tracked *.sh in the repo.
Whole-line comments are exempt: the rule is about what bash EXECUTES, and this
repo's comments legitimately quote the bad pattern while explaining it.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Bytes 0x80-0xFF, expressed portably and without embedding raw high bytes in this
# source file: under LC_ALL=C, [:print:] is 0x20-0x7E and [:cntrl:] is 0x00-0x1F plus
# 0x7F, so the complement of their union is exactly the non-ASCII range. POSIX ERE
# only -- no GNU-only `grep -P`, so this behaves identically on BSD grep (macOS
# operator laptop) and GNU grep (ubuntu-latest runner).
#
# `\$[A-Za-z_][A-Za-z0-9_]*` deliberately excludes `${VAR}` (next char is `{`, not a
# name character) and positional params like `$1` (a single-character name cannot
# absorb a following byte, so they are not vulnerable). Narrow on purpose: every
# match should be a real defect, or the gate gets disabled the first week.
PATTERN='\$[A-Za-z_][A-Za-z0-9_]*[^[:cntrl:][:print:]]'

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    files+=("$f")
  done < <(git ls-files '*.sh')
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "brace-guard: no shell files to check"
  exit 0
fi

rc=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  # Blank whole-line comments rather than deleting them, so `grep -n` line numbers
  # still point at the real line in the real file.
  if hits="$(awk '{ if ($0 ~ /^[[:space:]]*#/) print ""; else print }' "$f" \
             | LC_ALL=C grep -nE "$PATTERN")"; then
    while IFS= read -r hit; do
      printf '%s:%s\n' "$f" "$hit"
    done <<< "$hits"
    rc=1
  fi
done

if [[ "$rc" -ne 0 ]]; then
  cat >&2 <<'EOF'

brace-guard: unbraced $VAR immediately followed by a non-ASCII character.

Bash resolves variable names byte-wise, so the first byte of the following
multi-byte character is swallowed into the name and `set -u` aborts at runtime --
after the AWS meter is already running. shellcheck cannot see this (it parses
Unicode, not bytes), which is why this check exists. See TSG-028 / IRD-014.

Fix: brace the expansion -- ${VAR} instead of $VAR.
EOF
fi

exit "$rc"
