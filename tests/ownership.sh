#!/usr/bin/env bash
# Ownership tests for Caffeinate Plus, run against the live plugin.
#
# Needs a running Noctalia with jonfriesen/caffeinate-plus loaded from this
# checkout. Drives the service over IPC and checks the real logind inhibitor
# held by Noctalia's built-in caffeine. It toggles caffeine as it goes and
# leaves it off. Takes about two minutes.
#
#   tests/ownership.sh

set -u

SERVICE="jonfriesen/caffeinate-plus:service"
TIMER_MIN="0.1" # 6 s timers
EXPIRY_WAIT=9   # timer + 1 s update tick + slack

pass=0
fail=0

p() { noctalia msg plugin "$SERVICE" all "$@" >/dev/null; }

caffeine() {
  if systemd-inhibit --list --no-pager --no-legend | grep -qE '^noctalia[[:space:]].*[[:space:]]idle[[:space:]]+Caffeine([[:space:]]|$)'; then
    echo on
  else
    echo off
  fi
}

# The service's own view, from the line `status` writes to the journal.
status() {
  local since
  since=$(date +%s)
  p status
  sleep 1
  journalctl --user --since "@$since" --no-pager -o cat | grep 'caffeinate-plus: active=' | tail -n1 |
    sed 's/.*caffeinate-plus: //'
}

check() { # name, expected, actual
  if [[ "$3" == *"$2"* ]]; then
    echo "  ok    $1"
    pass=$((pass + 1))
  else
    echo "  FAIL  $1: expected '$2', got '$3'"
    fail=$((fail + 1))
  fi
}

reset() {
  p cancel-timer
  p off
  noctalia msg caffeine-disable >/dev/null
  sleep 6 # let the service's 5 s poll settle
}

external_on() {
  noctalia msg caffeine-enable >/dev/null
  sleep 1
}

echo "timer starting from off"
reset
p add "$TIMER_MIN"
sleep 2
check "owns it, no takeover" "owned=true claimed=false" "$(status)"
sleep "$EXPIRY_WAIT"
check "off after expiry" "off" "$(caffeine)"

echo "add takes over caffeine that was already on"
reset
external_on
p add "$TIMER_MIN"
sleep 2
check "takeover recorded" "owned=true claimed=true" "$(status)"
sleep "$EXPIRY_WAIT"
check "off after expiry" "off" "$(caffeine)"

echo "preset (for) takes over caffeine that was already on"
reset
external_on
p for "$TIMER_MIN"
sleep 2
check "takeover recorded" "owned=true claimed=true" "$(status)"
sleep "$EXPIRY_WAIT"
check "off after expiry" "off" "$(caffeine)"

echo "replacing the timer keeps the takeover"
reset
external_on
p for 30
sleep 2
p for "$TIMER_MIN"
sleep 2
check "still taken over" "owned=true claimed=true" "$(status)"
sleep "$EXPIRY_WAIT"
check "off after expiry" "off" "$(caffeine)"

echo "cancel timer hands caffeine back"
reset
external_on
p for 30
sleep 2
p cancel-timer
sleep 1
check "handed back" "owned=false claimed=false" "$(status)"
check "still on" "on" "$(caffeine)"

echo "cancel timer keeps caffeine the plugin turned on"
reset
p enable
sleep 2
p for 30
sleep 2
p cancel-timer
sleep 1
check "still owned" "owned=true claimed=false" "$(status)"
check "still on" "on" "$(caffeine)"

echo "caffeine turned on elsewhere, no timer"
reset
external_on
sleep 6
check "not owned" "owned=false claimed=false session=false" "$(status)"

reset
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
