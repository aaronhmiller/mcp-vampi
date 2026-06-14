#!/usr/bin/env bash
#
# Curl-based end-to-end test harness for server.py (VAmPI MCP server),
# talking to it over the *streamable HTTP* transport instead of stdio.
#
# This is a direct port of test_client.py: same tool discovery + the same
# per-tool assertions against a live VAmPI instance. It exits non-zero if any
# check fails.
#
# Transport notes
# ---------------
# Each call is a JSON-RPC 2.0 POST to the /mcp endpoint with the headers from
# your sample:
#     -H "Mcp-Session-Id: <id>"
#     -H "Content-Type: application/json"
#     -H "Accept: application/json, text/event-stream"
# FastMCP replies as Server-Sent Events (event: message / data: {...}), so the
# harness strips the SSE framing and pulls out the JSON-RPC message whose id
# matches the request.
#
# Session handling
# ----------------
# Your example pinned a hardcoded Mcp-Session-Id. Those expire, so by default
# this harness runs the MCP `initialize` handshake itself and captures a fresh
# session id from the server's response header (then sends notifications/
# initialized). The session is reused for every subsequent call, which also
# preserves server.py's login/token cache across the run (the same property the
# stdio version got for free from a dedicated subprocess).
#
# To reuse a pre-existing session instead (skips the handshake):
#     MCP_SESSION_ID=a54a973ac9da4e049f0fa7e2724795e2 ./test_client_curl.sh
#
# Override the endpoint:
#     MCP_URL=http://3.19.71.128:8009/mcp ./test_client_curl.sh
#
# Requires: bash, curl, jq.

set -uo pipefail

MCP_URL="${MCP_URL:-http://3.19.71.128:8009/mcp}"
MCP_SESSION_ID="${MCP_SESSION_ID:-}"
PROTOCOL_VERSION="${MCP_PROTOCOL_VERSION:-2025-06-18}"

# ---- prerequisites ----------------------------------------------------------
for bin in curl jq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found on PATH" >&2; exit 2; }
done

# ---- result bookkeeping (mirrors check() in test_client.py) ------------------
PASS_COUNT=0
FAIL_COUNT=0
FAILED_NAMES=()

check() {
    # check <name> <true|false> [detail]
    local name="$1" cond="$2" detail="${3:-}"
    if [ "$cond" = "true" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf '[PASS] %s\n' "$name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_NAMES+=("$name")
        if [ -n "$detail" ]; then
            printf '[FAIL] %s  -- %s\n' "$name" "$detail"
        else
            printf '[FAIL] %s\n' "$name"
        fi
    fi
}

# ---- low-level helpers ------------------------------------------------------
RPC_ID=1

rand() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z' | tr -d '-' | cut -c1-8
    else
        printf '%08x' $((RANDOM * RANDOM))
    fi
}

# Pull the JSON-RPC message with id == $2 out of a (possibly SSE) response body.
extract_rpc() {
    local raw="$1" want="$2" line json mid last=""
    if printf '%s' "$raw" | grep -q '^data:'; then
        while IFS= read -r line; do
            line="${line%$'\r'}"
            case "$line" in
                data:*)
                    json="${line#data:}"; json="${json# }"
                    last="$json"
                    mid="$(printf '%s' "$json" | jq -r '.id // empty' 2>/dev/null)"
                    if [ "$mid" = "$want" ]; then
                        printf '%s' "$json"; return 0
                    fi
                    ;;
            esac
        done <<< "$raw"
        printf '%s' "$last"   # fallback: last data frame
    else
        printf '%s' "$raw"    # plain application/json response
    fi
}

# Send one JSON-RPC request, return the matching JSON-RPC message object.
mcp_rpc() {
    local method="$1" params="$2"
    local id=$RPC_ID
    RPC_ID=$((RPC_ID + 1))
    local body resp
    body="$(jq -nc --arg m "$method" --argjson p "$params" --argjson id "$id" \
        '{jsonrpc:"2.0", id:$id, method:$m, params:$p}')"
    resp="$(curl -sS -X POST "$MCP_URL" \
        -H "Mcp-Session-Id: $MCP_SESSION_ID" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        --data "$body")"
    extract_rpc "$resp" "$id"
}

# Extract the tool's returned dict from a tools/call response. Mirrors
# payload() in test_client.py: prefer structuredContent (unwrapping FastMCP's
# {"result": {...}} envelope), else parse the first text content block as JSON.
payload() {
    jq -c '
        (.result // {}) as $r
        | ($r.structuredContent) as $sc
        | if ($sc | type) == "object" then
            (if (($sc | keys) == ["result"]) and (($sc.result | type) == "object")
             then $sc.result else $sc end)
          else
            ((($r.content // [])[0].text // "{}") | (try fromjson catch {}))
          end
    ' 2>/dev/null <<< "$1"
}

# tool_call <name> <arguments-json>  -> prints the extracted payload dict
tool_call() {
    local tool="$1" args="${2:-{\}}"
    local params resp
    params="$(jq -nc --arg n "$tool" --argjson a "$args" '{name:$n, arguments:$a}')"
    resp="$(mcp_rpc "tools/call" "$params")"
    payload "$resp"
}

# ---- MCP session bring-up ---------------------------------------------------
mcp_initialize() {
    local init_body hdrs body session
    init_body="$(jq -nc --arg pv "$PROTOCOL_VERSION" '{
        jsonrpc:"2.0", id:0, method:"initialize",
        params:{
            protocolVersion:$pv,
            capabilities:{},
            clientInfo:{name:"curl-harness", version:"1.0"}
        }
    }')"
    hdrs="$(mktemp)"
    body="$(curl -sS -D "$hdrs" -X POST "$MCP_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        --data "$init_body")"
    session="$(grep -i '^mcp-session-id:' "$hdrs" | head -1 | awk -F': ' '{print $2}' | tr -d '\r\n ')"
    rm -f "$hdrs"

    if [ -z "$session" ]; then
        echo "error: server did not return an Mcp-Session-Id header on initialize" >&2
        echo "       (set MCP_SESSION_ID=... to supply one manually)" >&2
        exit 2
    fi
    MCP_SESSION_ID="$session"

    # Acknowledge per spec so the server marks the session ready.
    local note
    note="$(jq -nc '{jsonrpc:"2.0", method:"notifications/initialized", params:{}}')"
    curl -sS -X POST "$MCP_URL" \
        -H "Mcp-Session-Id: $MCP_SESSION_ID" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        --data "$note" >/dev/null

    local init_msg name proto
    init_msg="$(extract_rpc "$body" 0)"
    name="$(jq -r '.result.serverInfo.name // "?"' 2>/dev/null <<< "$init_msg")"
    proto="$(jq -r '.result.protocolVersion // "?"' 2>/dev/null <<< "$init_msg")"
    printf 'Connected to MCP server: %s (protocol %s)\n' "$name" "$proto"
}

# =============================================================================
main() {
    if [ -z "$MCP_SESSION_ID" ]; then
        mcp_initialize
    else
        printf 'Reusing supplied Mcp-Session-Id (skipping initialize handshake)\n'
    fi
    printf 'Endpoint: %s\n' "$MCP_URL"
    printf 'Session : %s\n\n' "$MCP_SESSION_ID"

    local r cond

    # ---- tool discovery -----------------------------------------------------
    local list_resp have missing
    list_resp="$(mcp_rpc "tools/list" '{}')"
    have="$(jq -r '.result.tools[]?.name' 2>/dev/null <<< "$list_resp" | sort)"
    local expected=(
        home create_db get_all_users debug_users register_user login
        get_current_user get_user_by_username update_email update_password
        delete_user get_all_books add_book get_book_by_title
    )
    missing="$(comm -23 \
        <(printf '%s\n' "${expected[@]}" | sort) \
        <(printf '%s\n' "$have"))"
    cond=$([ -z "$missing" ] && echo true || echo false)
    check "tools/list exposes all 14 tools" "$cond" "missing=$(echo "$missing" | tr '\n' ' ')"
    printf '  discovered tools: %s\n\n' "$(echo "$have" | tr '\n' ' ')"

    # ---- GET / --------------------------------------------------------------
    r="$(tool_call home '{}')"
    cond="$(jq -r 'if (.status_code==200) and ((.data|type)=="object") and (.data.vulnerable==1) then "true" else "false" end' <<< "$r")"
    check "home -> 200 + vulnerable flag" "$cond" "$r"

    # ---- GET /createdb (seed) ----------------------------------------------
    r="$(tool_call create_db '{}')"
    cond="$(jq -r 'if (.status_code==200) and (((.data.message)//"")|startswith("Database populated")) then "true" else "false" end' <<< "$r")"
    check "create_db -> 200 'Database populated.'" "$cond" "$r"

    # ---- GET /users/v1 ------------------------------------------------------
    r="$(tool_call get_all_users '{}')"
    cond="$(jq -r '
        ([.data.users[]?.username]) as $u
        | if (.status_code==200) and (($u|index("name1"))!=null) and (($u|index("name2"))!=null) and (($u|index("admin"))!=null)
          then "true" else "false" end' <<< "$r")"
    check "get_all_users -> 200 incl. seed users" "$cond" "$r"

    # ---- GET /users/v1/_debug ----------------------------------------------
    r="$(tool_call debug_users '{}')"
    cond="$(jq -r 'if (.status_code==200) and ([.data.users[]? | has("password")] | any) then "true" else "false" end' <<< "$r")"
    check "debug_users -> 200 exposes passwords" "$cond" "$r"

    # ---- POST /users/v1/register -------------------------------------------
    local newuser="tester_$(rand)"
    r="$(tool_call register_user "$(jq -nc --arg u "$newuser" '{username:$u, password:"pw123", email:($u+"@mail.com")}')")"
    cond="$(jq -r 'if (.status_code==200) and (.data.status=="success") then "true" else "false" end' <<< "$r")"
    check "register_user -> 200 success" "$cond" "$r"

    # duplicate registration -> 200 + "already exists"
    r="$(tool_call register_user '{"username":"name1","password":"x","email":"dupe@mail.com"}')"
    cond="$(jq -r 'if (.status_code==200) and (((.data.message)//""|ascii_downcase)|contains("already exists")) then "true" else "false" end' <<< "$r")"
    check "register_user duplicate -> 200 'already exists'" "$cond" "$r"

    # admin self-registration (vulnerable mode)
    local adminuser="admn_$(rand)"
    r="$(tool_call register_user "$(jq -nc --arg u "$adminuser" '{username:$u, password:"pw", email:($u+"@mail.com"), admin:true}')")"
    cond="$(jq -r 'if (.status_code==200) and (.data.status=="success") then "true" else "false" end' <<< "$r")"
    check "register_user admin=True -> 200" "$cond" "$r"

    # ---- POST /users/v1/login (bad password) -------------------------------
    r="$(tool_call login '{"username":"name1","password":"wrongpass"}')"
    cond="$(jq -r 'if (.session_token_set==false) then "true" else "false" end' <<< "$r")"
    check "login wrong password -> not authenticated" "$cond" "$r"

    # ---- POST /users/v1/login (good) ---------------------------------------
    r="$(tool_call login '{"username":"name1","password":"pass1"}')"
    cond="$(jq -r 'if (.status_code==200) and (.session_token_set==true) then "true" else "false" end' <<< "$r")"
    check "login name1 -> token cached" "$cond" "$r"

    # ---- GET /me (uses cached token) ---------------------------------------
    r="$(tool_call get_current_user '{}')"
    cond="$(jq -r 'if (.status_code==200) and (((.data.data.username)//"")=="name1") then "true" else "false" end' <<< "$r")"
    check "get_current_user -> 200 name1" "$cond" "$r"

    # ---- GET /me with explicit bad token -> 401 ----------------------------
    r="$(tool_call get_current_user '{"auth_token":"not.a.valid.token"}')"
    cond="$(jq -r 'if (.status_code==401) then "true" else "false" end' <<< "$r")"
    check "get_current_user bad token -> 401" "$cond" "$r"

    # ---- GET /users/v1/{username} ------------------------------------------
    r="$(tool_call get_user_by_username '{"username":"name1"}')"
    cond="$(jq -r 'if (.status_code==200) and (((.data.username)//"")=="name1") then "true" else "false" end' <<< "$r")"
    check "get_user_by_username name1 -> 200" "$cond" "$r"

    r="$(tool_call get_user_by_username "$(jq -nc --arg u "ghost_$(rand)" '{username:$u}')")"
    cond="$(jq -r 'if (.status_code==404) then "true" else "false" end' <<< "$r")"
    check "get_user_by_username missing -> 404" "$cond" "$r"

    # ---- POST /books/v1 (add) ----------------------------------------------
    local booktitle="book_$(rand)"
    r="$(tool_call add_book "$(jq -nc --arg t "$booktitle" '{book_title:$t, secret:"topsecret42"}')")"
    cond="$(jq -r 'if (.status_code==200) and (.data.status=="success") then "true" else "false" end' <<< "$r")"
    check "add_book -> 200 success" "$cond" "$r"

    # duplicate add -> 400
    r="$(tool_call add_book "$(jq -nc --arg t "$booktitle" '{book_title:$t, secret:"again"}')")"
    cond="$(jq -r 'if (.status_code==400) then "true" else "false" end' <<< "$r")"
    check "add_book duplicate -> 400" "$cond" "$r"

    # ---- GET /books/v1 ------------------------------------------------------
    r="$(tool_call get_all_books '{}')"
    cond="$(jq -r --arg t "$booktitle" 'if (.status_code==200) and (([.data.Books[]?.book_title]|index($t))!=null) then "true" else "false" end' <<< "$r")"
    check "get_all_books -> 200 incl. new book" "$cond" "$r"

    # ---- GET /books/v1/{title} (secret + BOLA) -----------------------------
    r="$(tool_call get_book_by_title "$(jq -nc --arg t "$booktitle" '{book_title:$t}')")"
    cond="$(jq -r 'if (.status_code==200) and (((.data.secret)//"")=="topsecret42") then "true" else "false" end' <<< "$r")"
    check "get_book_by_title -> 200 returns secret" "$cond" "$r"

    # add_book without valid auth -> 401
    r="$(tool_call add_book '{"book_title":"noauth","secret":"x","auth_token":"bad.token.here"}')"
    cond="$(jq -r 'if (.status_code==401) then "true" else "false" end' <<< "$r")"
    check "add_book bad token -> 401" "$cond" "$r"

    # ---- PUT /users/v1/{username}/email ------------------------------------
    r="$(tool_call update_email '{"username":"name1","email":"name1.new@mail.com"}')"
    cond="$(jq -r 'if (.status_code==204) then "true" else "false" end' <<< "$r")"
    check "update_email valid -> 204" "$cond" "$r"

    r="$(tool_call update_email '{"username":"name1","email":"not-an-email"}')"
    cond="$(jq -r 'if (.status_code==400) then "true" else "false" end' <<< "$r")"
    check "update_email invalid -> 400" "$cond" "$r"

    # ---- PUT /users/v1/{username}/password ---------------------------------
    r="$(tool_call update_password '{"username":"name1","password":"pass1new"}')"
    cond="$(jq -r 'if (.status_code==204) then "true" else "false" end' <<< "$r")"
    check "update_password -> 204" "$cond" "$r"
    # restore original password for cleanliness
    tool_call update_password '{"username":"name1","password":"pass1"}' >/dev/null

    # ---- DELETE /users/v1/{username} ---------------------------------------
    # name1 is NOT admin -> 401
    r="$(tool_call delete_user "$(jq -nc --arg u "$newuser" '{username:$u}')")"
    cond="$(jq -r 'if (.status_code==401) then "true" else "false" end' <<< "$r")"
    check "delete_user as non-admin -> 401" "$cond" "$r"

    # login as admin, then delete the throwaway user -> 200
    tool_call login '{"username":"admin","password":"pass1"}' >/dev/null
    r="$(tool_call delete_user "$(jq -nc --arg u "$newuser" '{username:$u}')")"
    cond="$(jq -r 'if (.status_code==200) and (.data.status=="success") then "true" else "false" end' <<< "$r")"
    check "delete_user as admin -> 200" "$cond" "$r"

    # delete nonexistent -> 404
    r="$(tool_call delete_user "$(jq -nc --arg u "ghost_$(rand)" '{username:$u}')")"
    cond="$(jq -r 'if (.status_code==404) then "true" else "false" end' <<< "$r")"
    check "delete_user missing -> 404" "$cond" "$r"

    # ---- summary ------------------------------------------------------------
    printf '\n==== %d passed, %d failed ====\n' "$PASS_COUNT" "$FAIL_COUNT"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        printf 'FAILED: %s\n' "$(IFS=', '; echo "${FAILED_NAMES[*]}")"
        exit 1
    fi
}

main "$@"
