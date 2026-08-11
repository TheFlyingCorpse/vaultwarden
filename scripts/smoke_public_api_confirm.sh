#!/usr/bin/env bash
#
# Smoke test for the organization Public API member confirm endpoint.
#
# Boots a throwaway Vaultwarden instance against a temporary SQLite database
# seeded with two organizations, mints an organization API token for each, then
# exercises GET /public/members/<id>/public-key and
# POST /public/members/<id>/confirm end to end and asserts on the resulting state.
#
# Confirming is the step that hands a member the organization key, so the tests
# cover the guards around that key as much as the happy path: the key is stored
# verbatim, an empty or missing key is refused, only an accepted invite can be
# confirmed (an invited, already confirmed or revoked member cannot), an owner is
# out of the Public API's reach, and an organization policy that would forbid the
# member from joining still blocks the confirm.
#
# The script exits non-zero if any assertion fails, so it is usable as a check.
#
# Requirements: bash, curl, jq, sqlite3, and either a prebuilt binary passed via
# the VW_BIN environment variable or a cargo toolchain to build one.
#
# Usage:
#   scripts/smoke_public_api_confirm.sh
#   VW_BIN=/path/to/vaultwarden PORT=8124 scripts/smoke_public_api_confirm.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

PORT="${PORT:-8084}"
VW_BIN="${VW_BIN:-$REPO_ROOT/target/debug/vaultwarden}"
API="http://127.0.0.1:$PORT"

# ---- fixtures -------------------------------------------------------------
ORG=22222222-2222-4222-8222-222222222222
# ORG2 carries an enabled two-factor policy, so it is where the policy guard is
# exercised without disturbing the confirms in ORG.
ORG2=99999999-9999-4999-8999-999999999999

USER=11111111-1111-4111-8111-111111111111
USER2=88888888-8888-4888-8888-888888888888
USER3=cccccccc-cccc-4ccc-8ccc-cccccccccccc
USER4=dddddddd-dddd-4ddd-8ddd-dddddddddddd
USER5=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
USER6=ffffffff-ffff-4fff-8fff-ffffffffffff
USER7=0a0a0a0a-0a0a-4a0a-8a0a-0a0a0a0a0a0a

# MEMBER is the only confirmed owner of ORG.
MEMBER=33333333-3333-4333-8333-333333333333
# MEMBER2 is the accepted member the happy path confirms.
MEMBER2=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
# MEMBER3 is still invited, MEMBER4 accepted without ever registering a key pair,
# MEMBER5 an accepted owner, MEMBER6 accepted but in ORG2, MEMBER7 revoked from
# accepted.
MEMBER3=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
MEMBER4=1b1b1b1b-1b1b-41b1-8b1b-1b1b1b1b1b1b
MEMBER5=2c2c2c2c-2c2c-42c2-8c2c-2c2c2c2c2c2c
MEMBER6=3d3d3d3d-3d3d-43d3-8d3d-3d3d3d3d3d3d
MEMBER7=4e4e4e4e-4e4e-44e4-8e4e-4e4e4e4e4e4e

APIKEYUUID=77777777-7777-4777-8777-777777777777
APIKEY=smoketestapikey1234567890
APIKEYUUID2=66666666-6666-4666-8666-666666666666
APIKEY2=smoketestapikey0987654321

POLICYUUID=55555555-5555-4555-8555-555555555555

# The server treats these as opaque strings; only a client can read them.
PUBKEY='MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsmokepublickey'
PUBKEY6='MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAotherorgpublickey'
ORGKEY='4.encryptedOrganizationKeyForTheMember=='
ORGKEY_ALT='4.aDifferentEncryptedOrganizationKey=='

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
export INVITATIONS_ALLOWED=true
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

# req METHOD PATH [TOKEN] -> sets HTTP_CODE, body written to $TMP/body
req() {
    local method="$1" path="$2" token="${3:-}"
    if [ -n "$token" ]; then
        HTTP_CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' \
            -X "$method" -H "Authorization: Bearer $token" "$API$path")
    else
        HTTP_CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X "$method" "$API$path")
    fi
}

# reqj METHOD PATH TOKEN JSON -> same, with a JSON request body
reqj() {
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

jqcheck() { # label filter expected
    check_eq "$1" "$(jqval "$2")" "$3"
}

sqlcheck() { # label sql expected
    check_eq "$1" "$(sqlite3 "$TMP/db.sqlite3" "$2")" "$3"
}

# A request body Rocket cannot deserialize is refused by Rocket itself, so which
# 4xx comes back is its choice rather than ours. Assert the refusal, not the code.
check_rejected() { # label actual
    if [ "$2" = "400" ] || [ "$2" = "422" ]; then
        pass "$1 (HTTP $2)"
    else
        fail "$1 (expected 400 or 422, got [$2])"
    fi
}

mint_token() { # org_id api_key -> prints the access token
    curl -sS -X POST "$API/identity/connect/token" \
        -d 'grant_type=client_credentials' \
        -d "client_id=organization.$1" \
        -d "client_secret=$2" \
        -d 'scope=api.organization' \
        -d 'device_identifier=7f7f7f7f-7f7f-47f7-8f7f-7f7f7f7f7f7f' \
        -d 'device_name=smoketest' \
        -d 'device_type=14' | jq -r '.access_token // empty'
}

# ---- boot once to run migrations, then seed, then boot to serve -----------
echo "== Booting once to create the database schema =="
start_server "$TMP/boot1.log"
stop_server

echo "== Seeding two organizations with members in every invite state =="
sqlite3 "$TMP/db.sqlite3" <<SQL
INSERT INTO users (uuid,enabled,created_at,updated_at,login_verify_count,email,name,password_hash,salt,password_iterations,akey,public_key,security_stamp,equivalent_domains,excluded_globals,client_kdf_type,client_kdf_iter)
VALUES
('$USER',1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,'alice@example.com','Alice Owner',X'00',X'00',100000,'',NULL,'stamp-1','[]','[]',0,100000),
('$USER2',1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,'bob@example.com','Bob Accepted',X'00',X'00',100000,'','$PUBKEY','stamp-2','[]','[]',0,100000),
('$USER3',1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,'carol@example.com','Carol Invited',X'00',X'00',100000,'','$PUBKEY','stamp-3','[]','[]',0,100000),
('$USER4',1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,'dave@example.com','Dave Keyless',X'00',X'00',100000,'',NULL,'stamp-4','[]','[]',0,100000),
('$USER5',1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,'erin@example.com','Erin Owner',X'00',X'00',100000,'','$PUBKEY','stamp-5','[]','[]',0,100000),
('$USER6',1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,'frank@example.com','Frank Other',X'00',X'00',100000,'','$PUBKEY6','stamp-6','[]','[]',0,100000),
('$USER7',1,'2026-01-01 00:00:00','2026-01-01 00:00:00',0,'grace@example.com','Grace Revoked',X'00',X'00',100000,'','$PUBKEY','stamp-7','[]','[]',0,100000);

INSERT INTO organizations (uuid,name,billing_email,private_key,public_key) VALUES
('$ORG','Test Org','billing@example.com',NULL,NULL),
('$ORG2','Other Org','other@example.com',NULL,NULL);

INSERT INTO organization_api_key (uuid,org_uuid,atype,api_key,revision_date) VALUES
('$APIKEYUUID','$ORG',0,'$APIKEY','2026-01-01 00:00:00'),
('$APIKEYUUID2','$ORG2',0,'$APIKEY2','2026-01-01 00:00:00');

-- ORG2 requires two-factor, which forbids a member below Admin from joining.
INSERT INTO org_policies (uuid,org_uuid,atype,enabled,data) VALUES
('$POLICYUUID','$ORG2',0,1,'null');

-- atype 0 is Owner and 2 is User. status 0 is Invited, 1 Accepted, 2 Confirmed;
-- a revoked member carries its pre-revocation status minus 128, so -127 is a
-- member that was revoked while accepted.
INSERT INTO users_organizations (uuid,user_uuid,org_uuid,invited_by_email,access_all,akey,status,atype,reset_password_key,external_id) VALUES
('$MEMBER','$USER','$ORG',NULL,0,'',2,0,NULL,'ext-owner'),
('$MEMBER2','$USER2','$ORG',NULL,0,'',1,2,NULL,'ext-accepted'),
('$MEMBER3','$USER3','$ORG',NULL,0,'',0,2,NULL,'ext-invited'),
('$MEMBER4','$USER4','$ORG',NULL,0,'',1,2,NULL,'ext-keyless'),
('$MEMBER5','$USER5','$ORG',NULL,0,'',1,0,NULL,'ext-accepted-owner'),
('$MEMBER6','$USER6','$ORG2',NULL,0,'',1,2,NULL,'ext-other-org'),
('$MEMBER7','$USER7','$ORG',NULL,0,'',-127,2,NULL,'ext-revoked');
SQL

echo "== Booting to serve =="
start_server "$TMP/boot2.log"

echo "== Minting organization API tokens =="
TOKEN=$(mint_token "$ORG" "$APIKEY")
TOKEN2=$(mint_token "$ORG2" "$APIKEY2")

if [ -z "$TOKEN" ] || [ -z "$TOKEN2" ]; then
    echo "FAIL: could not mint an organization API token" >&2
    exit 1
fi
pass "minted organization API tokens for both organizations"

echo ""
echo "== Read the public key to encrypt the organization key against =="

req GET "/api/public/members/$MEMBER2/public-key" "$TOKEN"
check_eq "read public key -> 200" "$HTTP_CODE" "200"
jqcheck "public key object" '.object' "memberPublicKey"
jqcheck "public key member id" '.id' "$MEMBER2"
jqcheck "public key user id" '.userId' "$USER2"
jqcheck "public key value" '.publicKey' "$PUBKEY"

req GET "/api/public/members/$MEMBER4/public-key" "$TOKEN"
check_eq "member that never registered a key pair -> 404" "$HTTP_CODE" "404"

req GET "/api/public/members/$MEMBER6/public-key" "$TOKEN"
check_eq "public key of another organization's member -> 404" "$HTTP_CODE" "404"

req GET "/api/public/members/$MEMBER2/public-key"
check_eq "read public key with no token -> 401" "$HTTP_CODE" "401"

echo ""
echo "== Confirm an accepted member =="

reqj POST "/api/public/members/$MEMBER2/confirm" "$TOKEN" "{\"key\":\"$ORGKEY\"}"
check_eq "confirm accepted member -> 200" "$HTTP_CODE" "200"
sqlcheck "member is now confirmed" \
    "SELECT status FROM users_organizations WHERE uuid='$MEMBER2';" "2"
sqlcheck "the organization key is stored verbatim" \
    "SELECT akey FROM users_organizations WHERE uuid='$MEMBER2';" "$ORGKEY"

req GET "/api/public/members/$MEMBER2" "$TOKEN"
jqcheck "the member reads back as confirmed" '.status' "2"

echo ""
echo "== Only an accepted invite can be confirmed =="

reqj POST "/api/public/members/$MEMBER2/confirm" "$TOKEN" "{\"key\":\"$ORGKEY_ALT\"}"
check_eq "confirm an already confirmed member -> 400" "$HTTP_CODE" "400"
sqlcheck "the second confirm did not overwrite the stored key" \
    "SELECT akey FROM users_organizations WHERE uuid='$MEMBER2';" "$ORGKEY"

reqj POST "/api/public/members/$MEMBER3/confirm" "$TOKEN" "{\"key\":\"$ORGKEY\"}"
check_eq "confirm an invited member -> 400" "$HTTP_CODE" "400"
sqlcheck "the invited member is untouched" \
    "SELECT status || '|' || akey FROM users_organizations WHERE uuid='$MEMBER3';" "0|"

reqj POST "/api/public/members/$MEMBER7/confirm" "$TOKEN" "{\"key\":\"$ORGKEY\"}"
check_eq "confirm a member revoked while accepted -> 400" "$HTTP_CODE" "400"
sqlcheck "the revoked member stays revoked" \
    "SELECT status FROM users_organizations WHERE uuid='$MEMBER7';" "-127"

echo ""
echo "== A key is required, because a member without one cannot decrypt anything =="

reqj POST "/api/public/members/$MEMBER4/confirm" "$TOKEN" '{"key":""}'
check_eq "confirm with an empty key -> 400" "$HTTP_CODE" "400"
reqj POST "/api/public/members/$MEMBER4/confirm" "$TOKEN" '{}'
check_rejected "confirm with no key field is refused" "$HTTP_CODE"
sqlcheck "the keyless confirms left the member accepted" \
    "SELECT status || '|' || akey FROM users_organizations WHERE uuid='$MEMBER4';" "1|"

echo ""
echo "== Ownership stays out of the Public API's reach =="

reqj POST "/api/public/members/$MEMBER5/confirm" "$TOKEN" "{\"key\":\"$ORGKEY\"}"
check_eq "confirm an accepted owner -> 400" "$HTTP_CODE" "400"
sqlcheck "the accepted owner is untouched" \
    "SELECT status || '|' || akey FROM users_organizations WHERE uuid='$MEMBER5';" "1|"

echo ""
echo "== The organization boundary and authentication =="

reqj POST "/api/public/members/$MEMBER6/confirm" "$TOKEN" "{\"key\":\"$ORGKEY\"}"
check_eq "confirm a member of another organization -> 404" "$HTTP_CODE" "404"
sqlcheck "the other organization's member is untouched" \
    "SELECT status FROM users_organizations WHERE uuid='$MEMBER6';" "1"

reqj POST "/api/public/members/00000000-0000-4000-8000-000000000000/confirm" "$TOKEN" "{\"key\":\"$ORGKEY\"}"
check_eq "confirm an unknown member -> 404" "$HTTP_CODE" "404"

reqj POST "/api/public/members/$MEMBER4/confirm" "" "{\"key\":\"$ORGKEY\"}"
check_eq "confirm with no token -> 401" "$HTTP_CODE" "401"
sqlcheck "the unauthenticated confirm changed nothing" \
    "SELECT status FROM users_organizations WHERE uuid='$MEMBER4';" "1"

echo ""
echo "== An organization policy that forbids joining also forbids confirming =="

reqj POST "/api/public/members/$MEMBER6/confirm" "$TOKEN2" "{\"key\":\"$ORGKEY\"}"
check_eq "confirm blocked by the two-factor policy -> 400" "$HTTP_CODE" "400"
sqlcheck "the policy-blocked member stays accepted without a key" \
    "SELECT status || '|' || akey FROM users_organizations WHERE uuid='$MEMBER6';" "1|"

echo ""
echo "== The confirm is recorded in the event log =="

sqlcheck "OrganizationUserConfirmed logged for the confirmed member" \
    "SELECT COUNT(*) FROM event WHERE org_uuid='$ORG' AND event_type=1501 AND org_user_uuid='$MEMBER2';" "1"
sqlcheck "no event was logged for a rejected confirm" \
    "SELECT COUNT(*) FROM event WHERE event_type=1501 AND org_user_uuid<>'$MEMBER2';" "0"
sqlcheck "the confirm event records no acting user" \
    "SELECT COUNT(*) FROM event WHERE event_type=1501 AND act_user_uuid IS NOT NULL;" "0"
sqlcheck "the confirm event records no device type" \
    "SELECT COUNT(*) FROM event WHERE event_type=1501 AND device_type IS NOT NULL;" "0"
sqlcheck "the confirm event records the client address" \
    "SELECT COUNT(*) FROM event WHERE event_type=1501 AND ip_address IS NULL;" "0"

echo ""
if [ "$FAILS" -ne 0 ]; then
    echo "RESULT: $FAILS assertion(s) failed."
    exit 1
fi
echo "RESULT: all assertions passed."
