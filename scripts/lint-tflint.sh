#!/usr/bin/env bash
# ===========================================================================
# lint-tflint.sh — the LOCAL twin of reusable-iac.yml@v6's TFLint step (MIN-69).
#
# THE GAP. CI has run `tflint` on every Terraform root since D11, but nothing ran it
# locally: no hook, no Taskfile task. A contributor could commit a tflint violation
# and learn about it only minutes later in CI — or, for a change made during a metered
# window, with the AWS meter running. Mirror image of MIN-60 (a hook with no CI twin).
#
# WHAT "PARITY" MEANS HERE — mirrored step by step, not approximately:
#   CI (reusable-iac.yml, per root):   working-directory: envs/<root>
#                                      tflint --init
#                                      tflint --chdir=. --recursive
#   Here:                              ( cd envs/<root> && the same two commands )
# - Same VERSION: the pre-commit hook builds tflint v0.53.0 into its own env
#   (`language: golang`) — the exact version `setup-tflint` installs in CI (TSG-020).
# - Same CONFIG: none. No .tflint.hcl exists in this repo, so both sides run the
#   bundled `terraform` ruleset at its default preset and `--init` is a no-op. Adding a
#   .tflint.hcl changes CI too — that is a contract change, not a local tweak.
# - Same SCOPE: the two roots only. CI never lints modules/ as a standalone directory;
#   linting it here would make local STRICTER than CI, which is drift in the other
#   direction (MIN-69 Q3).
#
# ROOTS are listed explicitly and kept identical to iac-pr-opened.yml's paths-filter
# (`global`, `k3s_dev`). A root listed here that no longer exists FAILS instead of being
# skipped — a gate that silently lints nothing is the defect class this repo keeps
# paying for. Add `envs/eks-window` here when Phase 9 creates it.
#
# Usage: ./scripts/lint-tflint.sh
#        Needs `tflint` on PATH — the pre-commit hook provides it; run it via
#        `task tflint` or `pre-commit run tflint --all-files`. Read-only, $0, no AWS.
#        Exit 0 = clean, non-zero = findings or errors in at least one root.
# ===========================================================================
set -euo pipefail

ROOTS=("envs/global" "envs/k3s-dev")

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if ! command -v tflint >/dev/null 2>&1; then
  echo "lint-tflint: tflint not found on PATH — run via 'task tflint' so pre-commit supplies the pinned v0.53.0" >&2
  exit 1
fi

# Print the version the hook ACTUALLY runs, so the lockstep with CI is verified from
# output rather than from a config line (MIN-69 AC-2).
tflint --version

rc=0
for root in "${ROOTS[@]}"; do
  if [[ ! -d "$root" ]]; then
    echo "lint-tflint: root '${root}' does not exist — update ROOTS in this script and iac-pr-opened.yml's filter together" >&2
    rc=1
    continue
  fi
  echo "==> tflint ${root}"
  # Subshell: each root is linted from inside its own directory, exactly as CI's
  # `working-directory:` does. Keep going after a failing root so one run reports all.
  if ! ( cd "$root" && tflint --init && tflint --chdir=. --recursive ); then
    rc=1
  fi
done

exit "$rc"
