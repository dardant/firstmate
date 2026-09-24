#!/usr/bin/env bash
# Adversarial checks for the two rewritten cases in tests/fm-test-run.test.sh.
# Runs the real case functions (extracted from the test file) against mutated
# inputs and expects each mutation to be caught. Usage: harness.sh <worktree>
set -u
WT=$1
cd "$WT"
. tests/lib.sh
set +e

extract() { sed -n "/^$1() {/,/^}/p" tests/fm-test-run.test.sh; }
eval "$(extract test_jobs_admits_a_concurrent_safe_family)"
eval "$(extract test_herdr_ci_family_run_has_a_step_timeout)"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-adv.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
ok=0; bad=0
expect() { # expect <pass|fail> <label> <cmd...>
  local want=$1 label=$2; shift 2
  local out rc
  out=$("$@" 2>&1); rc=$?
  printf -- '--- %s (want %s, rc=%s)\n%s\n' "$label" "$want" "$rc" "$out"
  if { [ "$want" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; then
    ok=$((ok + 1)); echo "RESULT: as expected"
  else
    bad=$((bad + 1)); echo "RESULT: UNEXPECTED"
  fi
}

# --- jobs admission case ---------------------------------------------------
expect pass "jobs admission: real runner" \
  bash -c "$(declare -f fail pass test_jobs_admits_a_concurrent_safe_family); ROOT='$ROOT'; RUNNER='$ROOT/bin/fm-test-run.sh'; set -u; test_jobs_admits_a_concurrent_safe_family"

sed '/^list_concurrent_safe_families() {/,/^}/ s/^watcher-wake-lock$/__removed__/' \
  bin/fm-test-run.sh >"$scratch/runner-no-family.sh"
chmod +x "$scratch/runner-no-family.sh"
expect fail "jobs admission: runner mutated to drop watcher-wake-lock concurrency proof" \
  bash -c "$(declare -f fail pass test_jobs_admits_a_concurrent_safe_family); ROOT='$ROOT'; RUNNER='$scratch/runner-no-family.sh'; set -u; test_jobs_admits_a_concurrent_safe_family"

sed 's/^    watcher-wake-lock|pure-contract-unit|pr-forge) printf .4.n. ;;$/    watcher-wake-lock|pure-contract-unit|pr-forge) printf "9\\n" ;;/' \
  bin/fm-test-run.sh >"$scratch/runner-cap9.sh"
chmod +x "$scratch/runner-cap9.sh"
grep -q 'printf "9' "$scratch/runner-cap9.sh" || echo "WARN: cap mutation did not apply"
expect fail "jobs admission: runner mutated to raise the family cap 4 -> 9 (over-cap --jobs 5 must be refused)" \
  bash -c "$(declare -f fail pass test_jobs_admits_a_concurrent_safe_family); ROOT='$ROOT'; RUNNER='$scratch/runner-cap9.sh'; set -u; test_jobs_admits_a_concurrent_safe_family"

# --- Herdr CI step-timeout case (python3 yaml path; ruby absent here) --------
mkroot() { # mkroot <name> <python mutation of the parsed-then-dumped workflow, or empty>
  local r="$scratch/$1"
  mkdir -p "$r/.github/workflows"
  cp .github/workflows/ci.yml "$r/.github/workflows/ci.yml"
  if [ -n "$2" ]; then
    python3 - "$r/.github/workflows/ci.yml" "$2" <<'PY'
import sys, re
path, mode = sys.argv[1], sys.argv[2]
text = open(path).read()
lines = text.split("\n")
# locate the family-run step and its timeout-minutes line
i = next(n for n, l in enumerate(lines) if "Run real-Herdr family (serial, required)" in l)
j = next(n for n in range(i, len(lines)) if "timeout-minutes:" in lines[n])
if mode == "drop-step-timeout":
    del lines[j]
elif mode == "step-timeout-75":
    lines[j] = re.sub(r"timeout-minutes:\s*\d+", "timeout-minutes: 75", lines[j])
elif mode == "nested-with-name":
    # rename the real step and plant a decoy whose name sits under `with:`
    lines[i] = lines[i].replace("Run real-Herdr family (serial, required)", "Run something else")
    del lines[j]
    lines.insert(i + 1, lines[i].split("name:")[0].replace("-", " ") + "with:")
    lines.insert(i + 2, lines[i].split("name:")[0].replace("-", " ") + "  name: Run real-Herdr family (serial, required)")
    lines.insert(i + 3, lines[i].split("name:")[0].replace("-", " ") + "  timeout-minutes: 20")
open(path, "w").write("\n".join(lines))
PY
  fi
  printf '%s\n' "$r"
}
run_herdr() { # run_herdr <root> [PATH override]
  bash -c "$(declare -f fail pass test_herdr_ci_family_run_has_a_step_timeout); ROOT='$1'; set -u; ${2:+PATH='$2';} test_herdr_ci_family_run_has_a_step_timeout"
}
echo "ruby on PATH: $(command -v ruby || echo none)"
expect pass "herdr step timeout: real ci.yml via python3 yaml" run_herdr "$(mkroot real '')"
expect fail "herdr step timeout: family-run step timeout-minutes removed" run_herdr "$(mkroot drop drop-step-timeout)"
expect fail "herdr step timeout: family-run step timeout raised to 75" run_herdr "$(mkroot s75 step-timeout-75)"
expect fail "herdr step timeout: decoy nested with.name carries the step name" run_herdr "$(mkroot nested nested-with-name)"

# neither loader: python3 shim whose `import yaml` fails, no ruby
mkdir -p "$scratch/noyaml-bin"
cat >"$scratch/noyaml-bin/python3" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -c ] && [ "\${2:-}" = 'import yaml' ]; then exit 1; fi
exec $(command -v python3) "\$@"
SH
chmod +x "$scratch/noyaml-bin/python3"
expect fail "herdr step timeout: neither ruby nor python3 yaml available" \
  run_herdr "$(mkroot noyaml '')" "$scratch/noyaml-bin:$PATH"

echo "SUMMARY as_expected=$ok unexpected=$bad"
[ "$bad" -eq 0 ]
