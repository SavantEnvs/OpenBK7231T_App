#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the pre-built OpenBeken simulator tests (normal flags, built by mayhem/build.sh):
# upstream's own unit-test suite (`-runUnitTests 2`) plus known-answer checks through the real command
# interpreter, HTTP server and TuyaMCU driver. exit 0 = pass.
#

set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


for b in "$SRC/obk_selftest" "$SRC/obk_kat"; do
  [ -x "$b" ] || { echo "missing $b (mayhem/build.sh should have built it)" >&2; emit_ctrf "obk-selftest" 0 1 0; exit 1; }
done

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cd "$work"   # the simulator writes scratch files (sim_lastPublish*.txt, ...) to its cwd
passed=0; failed=0
ok()   { passed=$((passed+1)); echo "PASS: $1"; }
fail() { failed=$((failed+1)); echo "FAIL: $1" >&2; }

# 1. Upstream's self-test suite: each assertion failure prints "SelfTest assertion failed" and the
#    exit status is the error count. Also require that it really ran (about 1000 Test_* log lines,
#    hundreds of simulated boots), so a program that exits early or prints nothing fails.
timeout 1200 "$SRC/obk_selftest" -runUnitTests 2 > selftest.log 2>&1
rc=$?
errs=$(grep -ac 'SelfTest assertion failed' selftest.log)
tests=$(grep -ac 'Test_' selftest.log)
boots=$(grep -ac 'Main_Init_After_Delay done' selftest.log)
# Test_WS2812B (selftest_ws2812b.c, ~lines 480-500) sends DDP packets to 127.0.0.1 and needs the DDP
# receive socket, whose multicast IP_ADD_MEMBERSHIP on INADDR_ANY fails when the host has no route at all
# (an air-gapped `--network none` container). Without a route those four assertions cannot hold; with
# one they are enforced like every other assertion.
udp_errs=0
if [ -z "$(awk 'NR>1' /proc/net/route 2>/dev/null)" ]; then
  udp_errs=$(grep -aEc 'Check src/selftest/selftest_ws2812b\.c - Test_WS2812B - line (4[89][0-9]|500)$' selftest.log)
  echo "no IPv4 route: tolerating $udp_errs DDP assertion(s) in Test_WS2812B"
fi
real_errs=$((errs - udp_errs))
[ "$errs" -eq "$rc" ] && [ "$real_errs" -eq 0 ] && ok "selftest: no failed assertions (exit status $rc = $errs, $udp_errs no-route-only)" \
  || { fail "selftest rc=$rc assertion-failures=$errs (no-route-only: $udp_errs)"; grep -a -A2 'assertion failed' selftest.log | head -40 >&2; }
[ "$tests" -ge 1000 ] && [ "$boots" -ge 250 ] && ok "selftest ran to completion (Test_ lines=$tests boots=$boots)" \
  || fail "selftest output too short (Test_ lines=$tests boots=$boots, want >=1000 / >=250)"

# 2. Known-answer tests: command interpreter, expression evaluator, HTTP /cm endpoint, TuyaMCU parser.
timeout 120 "$SRC/obk_kat" > kat.out 2> kat.err
krc=$?
[ "$krc" -eq 0 ] || fail "obk_kat exit status $krc"
for want in \
  'KAT setChannel ch7=42' \
  'KAT expression ch8=85' \
  'KAT addChannel ch8=80' \
  'KAT http-cmnd ch9=13' \
  'KAT http-body=[13]' \
  'KAT http-cmnd2 ch9=77' \
  'KAT tuyamcu dp1=1' \
  'KAT flash-dirtied=1' \
  'KAT flash-reset-blank=1' \
  'KAT flash-deterministic=1'; do
  if grep -qxF "$want" kat.err; then ok "$want"; else fail "expected '$want'"; fi
done
[ "$failed" -eq 0 ] || { echo "--- obk_kat stderr ---" >&2; cat kat.err >&2; }

emit_ctrf "obk-selftest-kat" "$passed" "$failed" 0
