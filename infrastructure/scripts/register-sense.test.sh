#!/usr/bin/env bash
#
# Tests scripts/register-sense.sh against a throwaway database in the running
# compose Postgres (make up). The orb database itself is never touched.
#
#   ./scripts/register-sense.test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

TEST_DB=orb_register_test
PGUSER=${POSTGRES_USER:-hello}
SENSE=AAAAAAAAAAAAAAAA
OTHER_SENSE=BBBBBBBBBBBBBBBB
KEY=00112233445566778899aabbccddeeff

admin() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d postgres -qtA -c "$1" </dev/null >/dev/null; }
q() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$TEST_DB" -qtA -c "$1" </dev/null; }
register() { POSTGRES_DB=$TEST_DB ./scripts/register-sense.sh "$@" </dev/null >/dev/null 2>&1; }

failures=0
check() { # name, expected, actual
  if [ "$2" == "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}

reset_db() {
  admin "DROP DATABASE IF EXISTS $TEST_DB"
  admin "CREATE DATABASE $TEST_DB"
  POSTGRES_DB=$TEST_DB ./scripts/migrate.sh </dev/null >/dev/null
  q "INSERT INTO accounts (email, password_hash, created_at) VALUES
       ('sleeper@example.com', 'x', '2026-01-01T00:00:00Z'),
       ('paired@example.com',  'x', '2026-01-01T00:00:00Z')" >/dev/null
  q "INSERT INTO senses (device_id, aes_key) VALUES ('$OTHER_SENSE', '\\x00')" >/dev/null
  q "INSERT INTO account_senses (account_id, device_id)
     SELECT id, '$OTHER_SENSE' FROM accounts WHERE email = 'paired@example.com'" >/dev/null
}
trap 'admin "DROP DATABASE IF EXISTS $TEST_DB"' EXIT

# Registering stores the key, pairs the Sense and sets the account's zone, so
# orb accepts the device and renders its readings in local time.
reset_db
register "$SENSE" "$KEY" Sleeper@Example.com Europe/Berlin || echo "FAIL register exited non-zero"
check "stores the device key" "$KEY" \
  "$(q "SELECT encode(aes_key, 'hex') FROM senses WHERE device_id = '$SENSE'")"
check "pairs the Sense to the account" "t" \
  "$(q "SELECT active FROM account_senses s JOIN accounts a ON a.id = s.account_id
        WHERE a.email = 'sleeper@example.com' AND s.device_id = '$SENSE'")"
check "records the zone from the account's creation" "Europe/Berlin|2026-01-01 00:00:00+00" \
  "$(q "SELECT timezone_id || '|' || (effective_from AT TIME ZONE 'UTC') || '+00' FROM timezone_history")"
berlin_now=$(q "SELECT (EXTRACT(EPOCH FROM (now() AT TIME ZONE 'Europe/Berlin') - (now() AT TIME ZONE 'UTC')) * 1000)::int")
check "uses the zone's offset today, for the zone and the account fallback" "$berlin_now|$berlin_now" \
  "$(q "SELECT offset_ms FROM timezone_history")|$(q "SELECT tz_offset_ms FROM accounts WHERE email = 'sleeper@example.com'")"

# Running it twice changes nothing: a retry must not stack zone changes.
register "$SENSE" "$KEY" sleeper@example.com Europe/Berlin || echo "FAIL re-register exited non-zero"
check "re-running adds no zone change" "1" "$(q "SELECT count(*) FROM timezone_history")"
check "re-running keeps one pairing" "1" "$(q "SELECT count(*) FROM account_senses WHERE device_id = '$SENSE'")"

# Refusals leave the database exactly as it was.
while IFS='|' read -r name device email zone; do
  reset_db
  before="$(q "SELECT count(*) FROM senses")|$(q "SELECT count(*) FROM account_senses")"
  if register "$device" "$KEY" "$email" "$zone"; then status=accepted; else status=refused; fi
  check "refuses $name" "refused" "$status"
  check "leaves nothing behind when refusing $name" "$before" \
    "$(q "SELECT count(*) FROM senses")|$(q "SELECT count(*) FROM account_senses")"
done <<EOF
an unknown account|$SENSE|nobody@example.com|Europe/Berlin
an account that already has another Sense|$SENSE|paired@example.com|Europe/Berlin
an unknown zone|$SENSE|sleeper@example.com|Europe/Atlantis
a malformed device id|not-a-device|sleeper@example.com|Europe/Berlin
EOF

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
