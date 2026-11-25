#!/usr/bin/env bash
# Lid inhibitor reconcile test for Caffeinate Plus, run against the live plugin.
#
# Needs a running Noctalia with jonfriesen/caffeinate-plus loaded from this
# checkout. Starts a session with Ignore lid close on, then ages the heartbeat
# file the way a long suspend does, so the lid unit exits on its own. The
# plugin should notice and start the unit again. Leaves caffeine and the lid
# off. Takes about half a minute.
#
#   tests/lid.sh

set -u

SERVICE="jonfriesen/caffeinate-plus:service"
UNIT="caffeinate-plus-lid.service"
HEARTBEAT="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/plugins/data/jonfriesen/caffeinate-plus/lid-heartbeat"

pass=0
fail=0

p() { noctalia msg plugin "$SERVICE" all "$@" >/dev/null; }

unit() { systemctl --user is-active --quiet "$UNIT" && echo active || echo inactive; }

# Empty once the unit is gone (it's --collect); a new value for each start.
invocation() { systemctl --user show -p InvocationID --value "$UNIT" 2>/dev/null; }

check_unit() { # name, expected state; exact, since "inactive" contains "active"
  local got
  got=$(unit)
  if [ "$got" = "$2" ]; then
    echo "  ok    $1"
    pass=$((pass + 1))
  else
    echo "  FAIL  $1: expected unit $2, got $got"
    fail=$((fail + 1))
  fi
}

status() {
  local since
  since=$(date +%s)
  p status
  sleep 1
  journalctl --user --since "@$since" --no-pager -o cat | grep 'caffeinate-plus: active=' | tail -n1 |
    sed 's/.*caffeinate-plus: //'
}

check() { # name, expected (substring), actual
  if [[ "$3" == *"$2"* ]]; then
    echo "  ok    $1"
    pass=$((pass + 1))
  else
    echo "  FAIL  $1: expected '$2', got '$3'"
    fail=$((fail + 1))
  fi
}

if [ ! -d "$(dirname "$HEARTBEAT")" ]; then
  echo "plugin data dir not found: $(dirname "$HEARTBEAT")" >&2
  exit 2
fi

echo "lid unit that dies on its own is started again"
p off
p lid on
p enable
sleep 3
check_unit "unit held" active

# Wait for the plugin's next heartbeat, then age it: the unit has the full
# 10 s until the following heartbeat to see it stale and exit.
before=$(stat -c %Y "$HEARTBEAT" 2>/dev/null || echo 0)
for _ in $(seq 12); do
  [ "$(stat -c %Y "$HEARTBEAT" 2>/dev/null || echo 0)" != "$before" ] && break
  sleep 1
done
first=$(invocation)
touch -d '-60 sec' "$HEARTBEAT"
# The unit sees the stale heartbeat within 5 s and exits; the plugin's next lid
# poll (5 s) should start a new one. A new invocation id proves it restarted.
for _ in $(seq 15); do
  [ "$(unit)" = active ] && [ "$(invocation)" != "$first" ] && break
  sleep 1
done
check "unit exited and started again" "restarted" \
  "$(now=$(invocation); [ -n "$now" ] && [ "$now" != "$first" ] && echo restarted || echo "no new start (was $first, now ${now:-none})")"
check_unit "unit held again" active
check "plugin reports it held" "lid=true/true" "$(status)"

p off
p lid off
sleep 3
check_unit "released after off" inactive

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
