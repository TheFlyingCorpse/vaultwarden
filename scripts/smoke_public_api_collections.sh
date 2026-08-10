#!/usr/bin/env bash
#
# Smoke test for the organization Public API collection write endpoints.
#
# Boots a throwaway Vaultwarden instance against a temporary SQLite database
# seeded with two organizations, mints an organization API token for the first
# org, then exercises PUT and DELETE on /public/collections.
#
# Upstream has no create route, because a collection name is end-to-end
# encrypted ciphertext the server cannot produce, so externalId is the only
# server-legible handle on a collection and PUT is the only way to set it.
#
# It also asserts that the group list carries each group's collection
# associations, which upstream includes and the member and collection lists
# deliberately omit.
#
# The script exits non-zero if any assertion fails, so it is usable as a check.
#
# Requirements: bash, curl, jq, sqlite3, and either a prebuilt binary passed via
# the VW_BIN environment variable or a cargo toolchain to build one.
#
# Usage:
#   scripts/smoke_public_api_collections.sh
#   VW_BIN=/path/to/vaultwarden PORT=8123 scripts/smoke_public_api_collections.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PORT="${PORT:-8083}"
VW_BIN="${VW_BIN:-$REPO_ROOT/target/debug/vaultwarden}"
API="http://127.0.0.1:$PORT"

# ---- fixtures -------------------------------------------------------------
ORG=22222222-2222-4222-8222-222222222222
ORG2=99999999-9999-4999-8999-999999999999
USER=11111111-1111-4111-8111-111111111111
MEMBER=33333333-3333-4333-8333-333333333333
GROUP=44444444-4444-4444-8444-444444444444
GROUP2=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
COLLECTION=55555555-5555-4555-8555-555555555555
COLLECTION2=66666666-6666-4666-8666-666666666666
APIKEYUUID=77777777-7777-4777-8777-777777777777
APIKEY=smoketestapikey1234567890

# ---- prerequisites --------------------------------------------------------
for tool in curl jq sqlite3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' is not installed" >&2
        exit 2
    fi
done

if [ ! -x "$VW_BIN" ]; then
    if command -v cargo >/dev/null 2>&1; then
        echo "Building vaultwarden (sqlite feature); this can take a while..."
        cargo build --features sqlite
    else
        echo "ERROR: no binary at '$VW_BIN' and no cargo toolchain to build one." >&2
        echo "Set VW_BIN to a prebuilt binary or install a Rust toolchain." >&2
        exit 2
    fi
fi

# ---- workspace + cleanup --------------------------------------------------
TMP=$(mktemp -d)
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

export DATA_FOLDER="$TMP"
export DATABASE_URL="sqlite://$TMP/db.sqlite3"
export ADMIN_TOKEN="smoketestadmintoken"
export ORG_GROUPS_ENABLED=true
export ORG_EVENTS_ENABLED=true
export WEB_VAULT_ENABLED=false
export ROCKET_PORT="$PORT"
export ROCKET_ADDRESS=127.0.0.1
export DOMAIN="http://localhost:$PORT"

# ---- server helpers -------------------------------------------------------
start_server() {
    local logfile="$1"
    "$VW_BIN" >"$logfile" 2>&1 &
    SERVER_PID=$!
    local i
    for i in $(seq 1 90); do
        if grep -q "Rocket has launched" "$logfile" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "ERROR: server exited during startup. Log:" >&2
            cat "$logfile" >&2
            return 1
        fi
        sleep 1
    done
    echo "ERROR: server did not launch within 90s. Log:" >&2
    cat "$logfile" >&2
    return 1
}

stop_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
}

# ---- assertion helpers ----------------------------------------------------
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

check_eq() { # label actual expected
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected [$3], got [$2])"
    fi
}

req() { # METHOD PATH [TOKEN]
    local method="$1" path="$2" token="${3:-}"
    if [ -n "$token" ]; then
        HTTP_CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' \
            -X "$method" -H "Authorization: Bearer $token" "$API$path")
    else
        HTTP_CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X "$method" "$API$path")
    fi
}

reqj() { # METHOD PATH TOKEN JSON
    local method="$1" path="$2" token="$3" body="$4"
    if [ -n "$token" ]; then
        HTTP_CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' \
            -X "$method" -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' -d "$body" "$API$path")
    else
        HTTP_CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' \
            -X "$method" -H 'Content-Type: application/json' -d "$body" "$API$path")
    fi
}

jqval() { jq -r "$1" "$TMP/body"; }
jqcheck() { check_eq "$1" "$(jqval "$2")" "$3"; }
sqlcheck() { check_eq "$1" "$(sqlite3 "$TMP/db.sqlite3" "$2")" "$3"; }

# ---- boot once to run migrations, then seed, then boot to serve -----------
echo "== Booting once to create the database schema =="
start_server "$TMP/boot1.log"
stop_server

echo "== Seeding two organizations with groups and collections =="
sqlite3 "$TMP/db.sqlite3" <<SQL
INSERT INTO users (uuid,enabled,created_at,updated_at,login_verify_count,email,name,password_hash,salt,password_iterations,akey,security_stamp,equivalent_domains,excluded_globals,client_kdf_type,client_kdf_iter)
VALUES ('$USER',1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,'alice@example.com','Alice Example',X'00',X'00',100000,'','stamp-1','[]','[]',0,100000);

INSERT INTO organizations (uuid,name,billing_email,private_key,public_key) VALUES
('$ORG','Test Org','billing@example.com',NULL,NULL),
('$ORG2','Other Org','other@example.com',NULL,NULL);

INSERT INTO organization_api_key (uuid,org_uuid,atype,api_key,revision_date) VALUES
('$APIKEYUUID','$ORG',0,'$APIKEY','2026-01-01 00:00:00');

INSERT INTO users_organizations (uuid,user_uuid,org_uuid,invited_by_email,access_all,akey,status,atype,reset_password_key,external_id) VALUES
('$MEMBER','$USER','$ORG',NULL,0,'',2,0,NULL,'ext-member-1');

INSERT INTO groups (uuid,organizations_uuid,name,access_all,external_id,creation_date,revision_date) VALUES
('$GROUP','$ORG','Engineering',0,'ext-group-1','2026-01-01 00:00:00','2026-01-01 00:00:00'),
('$GROUP2','$ORG2','Other Group',0,'ext-group-2','2026-01-01 00:00:00','2026-01-01 00:00:00');

-- The first collection is deliberately seeded with no external id, the case where a
-- creating service left it unlabelled and only the opaque uuid is known.
INSERT INTO collections (uuid,org_uuid,name,external_id) VALUES
('$COLLECTION','$ORG','2.encryptedCiphertextName==',NULL),
('$COLLECTION2','$ORG2','2.otherOrgCiphertext==','ext-collection-2');
SQL

echo "== Booting to serve =="
start_server "$TMP/boot2.log"

echo "== Minting an organization API token =="
TOKEN=$(curl -sS -X POST "$API/identity/connect/token" \
    -d 'grant_type=client_credentials' \
    -d "client_id=organization.$ORG" \
    -d "client_secret=$APIKEY" \
    -d 'scope=api.organization' \
    -d 'device_identifier=ffffffff-ffff-4fff-8fff-ffffffffffff' \
    -d 'device_name=smoketest' \
    -d 'device_type=14' | jq -r '.access_token // empty')

if [ -z "$TOKEN" ]; then
    echo "FAIL: could not mint an organization API token" >&2
    exit 1
fi
pass "minted organization API token"

echo ""
echo "== An unlabelled collection can be adopted by stamping an externalId =="

req GET "/api/public/collections/$COLLECTION" "$TOKEN"
check_eq "unlabelled collection -> 200" "$HTTP_CODE" "200"
jqcheck "starts with no externalId" '.externalId' "null"

reqj PUT "/api/public/collections/$COLLECTION" "$TOKEN" '{"externalId":"ext-adopted"}'
check_eq "stamp an externalId -> 200" "$HTTP_CODE" "200"
jqcheck "response carries the new externalId" '.externalId' "ext-adopted"
jqcheck "response keeps the collection discriminator" '.object' "collection"
jqcheck "the encrypted name is still not exposed" 'has("name")' "false"

req GET "/api/public/collections/$COLLECTION" "$TOKEN"
jqcheck "externalId persisted" '.externalId' "ext-adopted"

echo ""
echo "== Group associations =="

reqj PUT "/api/public/collections/$COLLECTION" "$TOKEN" \
    "{\"groups\":[{\"id\":\"$GROUP\",\"readOnly\":true,\"hidePasswords\":false,\"manage\":false}]}"
check_eq "assign a group -> 200" "$HTTP_CODE" "200"
jqcheck "response lists the group" '.groups | length' "1"
jqcheck "response group id" '.groups[0].id' "$GROUP"
jqcheck "response group readOnly" '.groups[0].readOnly' "true"

# An omitted groups list must leave the associations alone.
reqj PUT "/api/public/collections/$COLLECTION" "$TOKEN" '{"externalId":"ext-adopted-2"}'
check_eq "update without groups -> 200" "$HTTP_CODE" "200"
jqcheck "omitted groups leave associations alone" '.groups | length' "1"
jqcheck "externalId still applied" '.externalId' "ext-adopted-2"

# An explicit empty list does clear them.
reqj PUT "/api/public/collections/$COLLECTION" "$TOKEN" '{"groups":[]}'
check_eq "explicit empty groups -> 200" "$HTTP_CODE" "200"
jqcheck "explicit empty groups clears associations" '.groups | length' "0"
jqcheck "externalId survives a groups-only update" '.externalId' "ext-adopted-2"

echo ""
echo "== The group list carries its collection associations =="

reqj PUT "/api/public/collections/$COLLECTION" "$TOKEN" \
    "{\"groups\":[{\"id\":\"$GROUP\",\"readOnly\":false,\"hidePasswords\":false,\"manage\":true}]}"
check_eq "reassign the group -> 200" "$HTTP_CODE" "200"

req GET "/api/public/groups" "$TOKEN"
check_eq "group list -> 200" "$HTTP_CODE" "200"
jqcheck "group list includes collections" '.data[0].collections | length' "1"
jqcheck "group list collection id" '.data[0].collections[0].id' "$COLLECTION"
jqcheck "group list collection manage" '.data[0].collections[0].manage' "true"

echo ""
echo "== Input validation and scoping =="

reqj PUT "/api/public/collections/$COLLECTION" "$TOKEN" \
    "{\"groups\":[{\"id\":\"$GROUP2\"}]}"
check_eq "group from another org -> 400" "$HTTP_CODE" "400"

reqj PUT "/api/public/collections/$COLLECTION2" "$TOKEN" '{"externalId":"hijack"}'
check_eq "collection of another org -> 404" "$HTTP_CODE" "404"
req DELETE "/api/public/collections/$COLLECTION2" "$TOKEN"
check_eq "deleting a collection of another org -> 404" "$HTTP_CODE" "404"
sqlcheck "the other org's collection is untouched" \
    "SELECT external_id FROM collections WHERE uuid='$COLLECTION2';" "ext-collection-2"

echo ""
echo "== Authentication required =="

reqj PUT "/api/public/collections/$COLLECTION" "" '{"externalId":"notoken"}'
check_eq "update with no token -> 401" "$HTTP_CODE" "401"
req DELETE "/api/public/collections/$COLLECTION"
check_eq "delete with no token -> 401" "$HTTP_CODE" "401"
req GET "/api/public/collections/$COLLECTION" "$TOKEN"
check_eq "the unauthenticated calls changed nothing" "$HTTP_CODE" "200"

echo ""
echo "== Delete =="

req DELETE "/api/public/collections/$COLLECTION" "$TOKEN"
check_eq "delete collection -> 200" "$HTTP_CODE" "200"
req GET "/api/public/collections/$COLLECTION" "$TOKEN"
check_eq "deleted collection is gone -> 404" "$HTTP_CODE" "404"
sqlcheck "its group associations went with it" \
    "SELECT COUNT(*) FROM collections_groups WHERE collections_uuid='$COLLECTION';" "0"

echo ""
echo "== Writes are recorded in the event log without an acting user =="

stop_server

# 1301 CollectionUpdated, 1302 CollectionDeleted.
for pair in "1301:collection updated" "1302:collection deleted"; do
    code="${pair%%:*}"
    label="${pair#*:}"
    got=$(sqlite3 "$TMP/db.sqlite3" \
        "SELECT COUNT(*) > 0 FROM event WHERE org_uuid='$ORG' AND event_type=$code;")
    check_eq "event logged: $label" "$got" "1"
done

sqlcheck "no Public API event records an acting user" \
    "SELECT COUNT(*) FROM event WHERE org_uuid='$ORG' AND act_user_uuid IS NOT NULL;" "0"

echo ""
if [ "$FAILS" -ne 0 ]; then
    echo "RESULT: $FAILS assertion(s) failed."
    exit 1
fi
echo "RESULT: all assertions passed."
