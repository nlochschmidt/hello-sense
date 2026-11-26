#!/usr/bin/env bash
#
# Register a Sense with orb and pair it to an existing account, the way the
# app's Bluetooth pairing would, for people setting up without the app.
#
#   scripts/register-sense.sh <device-id> <aes-key-hex> <email> <zone>
#
#   device-id    16 hex characters, from the device's /hello/deviceid
#   aes-key-hex  32 hex characters, from the device's /cert/key.aes
#   email        an account that already exists (POST /v1/account creates one)
#   zone         an IANA zone such as Europe/London
#
# orb accepts a Sense only when it holds the device's key AND the device is
# paired to an account; with either missing, every request gets a 401. The
# zone is what the app would send on first launch: without it orb stores
# readings as UTC.
#
# Safe to re-run. Refuses, changing nothing, when the account is unknown, the
# zone is unknown, or the account already holds a different Sense (orb's own
# pairing rule: one Sense per account, any number of accounts per Sense).
#
# Reads POSTGRES_USER and POSTGRES_DB from .env if present.
set -euo pipefail

cd "$(dirname "$0")/.."

usage="usage: register-sense.sh <device-id> <aes-key-hex> <email> <zone>"
DEVICE=$(echo "${1:?$usage}" | tr a-f A-F)
KEY=$(echo "${2:?$usage}" | tr A-F a-f)
EMAIL=$(echo "${3:?$usage}" | tr A-Z a-z)
ZONE="${4:?$usage}"

[[ "$DEVICE" =~ ^[0-9A-F]{16}$ ]] || { echo "REFUSING: device id must be 16 hex characters, got '$1'" >&2; exit 1; }
[[ "$KEY" =~ ^[0-9a-f]{32}$ ]] || { echo "REFUSING: key must be 32 hex characters" >&2; exit 1; }

# Load .env, but let anything already in the environment win, as migrate.sh
# does.
if [ -f .env ]; then
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ -n "${!key+x}" ]] && continue
    export "$key=$val"
  done < .env
fi
PGUSER=${POSTGRES_USER:-hello}
PGDB=${POSTGRES_DB:-orb}

# Values travel as psql variables, never spliced into SQL text.
sql() {
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDB" -qtA \
    -v device="$DEVICE" -v key="$KEY" -v email="$EMAIL" -v zone="$ZONE"
}

ACCOUNT=$(sql <<<"SELECT id FROM accounts WHERE email = :'email';")
[ -n "$ACCOUNT" ] || { echo "REFUSING: no account for $EMAIL. Create one first (POST /v1/account)." >&2; exit 1; }

KNOWN_ZONE=$(sql <<<"SELECT 1 FROM pg_timezone_names WHERE name = :'zone';")
[ -n "$KNOWN_ZONE" ] || { echo "REFUSING: unknown time zone '$ZONE'. Use an IANA name such as Europe/London." >&2; exit 1; }

OTHER=$(sql <<<"SELECT device_id FROM account_senses
                WHERE account_id = $ACCOUNT AND active AND device_id <> :'device';")
[ -z "$OTHER" ] || { echo "REFUSING: $EMAIL is already paired to Sense $OTHER." >&2; exit 1; }

sql <<SQL
BEGIN;

INSERT INTO senses (device_id, aes_key) VALUES (:'device', decode(:'key', 'hex'))
ON CONFLICT (device_id) DO UPDATE SET aes_key = EXCLUDED.aes_key;

INSERT INTO account_senses (account_id, device_id, active) VALUES ($ACCOUNT, :'device', true)
ON CONFLICT (account_id, device_id) DO UPDATE SET active = true;

-- A zone change is appended, never overwritten, because every reading is
-- rendered with the zone in force at its time. The first zone applies from the
-- account's creation so readings taken before registering are local too.
-- Re-registering with the zone already in force adds nothing.
WITH offset_now AS (
  SELECT (EXTRACT(EPOCH FROM (now() AT TIME ZONE :'zone') - (now() AT TIME ZONE 'UTC')) * 1000)::int AS ms
), latest AS (
  SELECT timezone_id FROM timezone_history WHERE account_id = $ACCOUNT
  ORDER BY effective_from DESC LIMIT 1
)
INSERT INTO timezone_history (account_id, effective_from, timezone_id, offset_ms)
SELECT $ACCOUNT,
       CASE WHEN EXISTS (SELECT 1 FROM latest) THEN now()
            ELSE (SELECT created_at FROM accounts WHERE id = $ACCOUNT) END,
       :'zone', ms
FROM offset_now
WHERE NOT EXISTS (SELECT 1 FROM latest WHERE timezone_id = :'zone');

-- The account's own offset is orb's fallback when no zone row applies.
UPDATE accounts
SET tz_offset_ms = (EXTRACT(EPOCH FROM (now() AT TIME ZONE :'zone') - (now() AT TIME ZONE 'UTC')) * 1000)::int
WHERE id = $ACCOUNT;

COMMIT;
SQL

echo "Registered Sense $DEVICE to $EMAIL ($ZONE)."
