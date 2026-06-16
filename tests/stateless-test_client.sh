#!/usr/bin/env bash
#
# Curl-based end-to-end test harness for server.py (VAmPI MCP server),
# talking to it over the *stateless* streamable-HTTP transport.
#
# This is the stateless/JSON port of streaming-test_client_curl.sh. Same tool
# discovery + the same per-tool assertions against a live VAmPI instance. It
# exits non-zero if any check fails.
#
# What changed vs. the streamed version
# --------------------------------------
#   * Accept header is now "application/json" only (no text/event-stream), so
#     the server answers with a single JSON-RPC object, not an SSE frame.
#   * No `initialize` handshake and no Mcp-Session-Id header -- every POST is an
#     independent, stateless JSON-RPC call.
#
# SERVER PREREQUISITE (important)
# -------------------------------
# These calls only work if server.py runs FastMCP in stateless + JSON mode:
#
#     mcp.run(transport="streamable-http", stateless_http=True, json_response=True)
#
#   * stateless_http=True  -> no session required; session-less POSTs won't 400.
#   * json_response=True   -> responses are always Content-Type: application/json,
#                             regardless of the client's Accept header. This is
#                             the robust lever; the Accept change below is belt-
#                             and-suspenders. Without this flag a spec-strict
#                             server MAY return 406 to an application/json-only
#                             Accept.
#
# Caveat: server.py's login/token cache. The streamed harness relied on session
# state to keep the JWT cached across calls. Under stateless_http=True that only
# holds if the cache is a process-global in server.py (not bound to the MCP
# session). If it's session-bound, the auth-dependent checks (get_current_user
# without an explicit token, update_email, update_password, delete_user) may
# FAIL -- but every call still goes out as a JSON-RPC POST /mcp and returns
# JSON, which is the wire traffic you're generating regardless.
#
# Override the endpoint:
#     MCP_URL=http://3.19.71.128:8009/mcp ./stateless-test_client_curl.sh
#
# Requires: bash, curl, jq.

set -uo pipefail

MCP_URL="${MCP_URL:-http://18.225.109.199/mcp}"

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

# Pull the JSON-RPC message with id == $2 out of a response body. With
# json_response=True the body is already a single JSON object, so the else
# branch handles it directly. The SSE branch is kept defensively in case the
# server falls back to streaming (which would itself be a signal that
# json_response isn't taking effect).
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
        printf '%s' "$raw"    # plain application/json response (expected path)
    fi
}

# Send one JSON-RPC request, return the matching JSON-RPC message object.
# Stateless: no Mcp-Session-Id, Accept restricted to application/json.
mcp_rpc() {
    local method="$1" params="$2"
    local id=$RPC_ID
    RPC_ID=$((RPC_ID + 1))
    local body resp
    body="$(jq -nc --arg m "$method" --argjson p "$params" --argjson id "$id" \
        '{jsonrpc:"2.0", id:$id, method:$m, params:$p}')"
    resp="$(curl -sS -X POST "$MCP_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
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

# ---- preflight: confirm the server answers stateless + JSON -----------------
# Does one raw tools/list and reports the HTTP status + response Content-Type so
# you can see on the wire whether json_response/stateless_http are in effect.
preflight() {
    local raw code ctype
    raw="$(curl -sS -i -X POST "$MCP_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data '{"jsonrpc":"2.0","id":0,"method":"tools/list","params":{}}' 2>/dev/null)"
    code="$(printf '%s' "$raw" | awk 'NR==1{print $2}' | tr -d '\r')"
    ctype="$(printf '%s' "$raw" | grep -i '^content-type:' | head -1 | sed 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//' | tr -d '\r')"
    printf 'Preflight: HTTP %s, Content-Type: %s\n' "${code:-?}" "${ctype:-?}"
    case "$code" in
        406)
            echo "  -> 406: server refused application/json-only Accept." >&2
            echo "     Set json_response=True on the FastMCP server." >&2
            ;;
        400)
            echo "  -> 400: server likely wants a session id (not in stateless_http mode)." >&2
            echo "     Set stateless_http=True on the FastMCP server." >&2
            ;;
    esac
    case "$ctype" in
        *event-stream*)
            echo "  -> server is still streaming (SSE). json_response is not taking effect." >&2
            ;;
    esac
}

# =============================================================================
main() {
    printf 'Endpoint: %s\n' "$MCP_URL"
    printf 'Mode    : stateless, Accept: application/json\n\n'
    preflight
    printf '\n'

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
    # NOTE: relies on server-side token cache surviving across stateless calls.
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
    # NOTE: relies on server-side token cache (logged in as name1 above).
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
    # NOTE: relies on server-side token cache.
    r="$(tool_call update_email '{"username":"name1","email":"name1.new@mail.com"}')"
    cond="$(jq -r 'if (.status_code==204) then "true" else "false" end' <<< "$r")"
    check "update_email valid -> 204" "$cond" "$r"

    r="$(tool_call update_email '{"username":"name1","email":"not-an-email"}')"
    cond="$(jq -r 'if (.status_code==400) then "true" else "false" end' <<< "$r")"
    check "update_email invalid -> 400" "$cond" "$r"

    # ---- PUT /users/v1/{username}/password ---------------------------------
    # NOTE: relies on server-side token cache.
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
