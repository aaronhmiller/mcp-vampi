"""
VAmPI MCP Server
================

An MCP-compatible server exposing the OWASP VAmPI ("Vulnerable API") surface as
MCP tools. Converted from the crAPI MCP server: every crAPI endpoint/tool has
been re-mapped to its VAmPI equivalent (syntax, paths, JSON bodies, and auth).

VAmPI OpenAPI spec: openapi_specs/openapi3.yml (erev0s/VAmPI)
MCP spec:           2025-11-25

Transport: stdio (default FastMCP).
Config via environment:
    VAMPI_BASE_URL   Base URL of the running VAmPI instance
                     (default: http://localhost:5000)
    VAMPI_TIMEOUT    Per-request timeout in seconds (default: 30)

Auth model
----------
VAmPI uses JWT bearer tokens: `Authorization: Bearer <token>`.
Call `login` once to obtain and cache a token in the server session; subsequent
authenticated tools reuse it automatically. Any authenticated tool also accepts
an explicit `auth_token` argument to override the cached token for that call.
"""

from __future__ import annotations

import os
from typing import Any, Optional

import httpx
from mcp.server.fastmcp import FastMCP

# --------------------------------------------------------------------------- #
# Configuration & shared state
# --------------------------------------------------------------------------- #

BASE_URL = os.environ.get("VAMPI_BASE_URL", "http://172.31.43.19:5000").rstrip("/")
TIMEOUT = float(os.environ.get("VAMPI_TIMEOUT", "30"))

# Transport selection (default stdio so MCP clients can spawn it directly).
# For a long-running systemd service set MCP_TRANSPORT=streamable-http.
MCP_TRANSPORT = os.environ.get("MCP_TRANSPORT", "stdio")
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = int(os.environ.get("MCP_PORT", "8000"))
MCP_PATH = os.environ.get("MCP_PATH", "/mcp")


def _env_flag(name: str, default: bool) -> bool:
    return os.environ.get(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


# Streamable HTTP response framing (only relevant when MCP_TRANSPORT=streamable-http;
# stdio ignores both):
#   MCP_JSON_RESPONSE=true  -> POST /mcp replies as a single application/json body
#                              instead of a text/event-stream SSE event.
#   MCP_STATELESS=true      -> no per-session Mcp-Session-Id round-trip and no
#                              long-lived GET /mcp SSE notification channel.
# Set either to false to fall back to streaming for an A/B against the mirror.
MCP_JSON_RESPONSE = _env_flag("MCP_JSON_RESPONSE", True)
MCP_STATELESS = _env_flag("MCP_STATELESS", True)

mcp = FastMCP(
    "vampi",
    host=MCP_HOST,
    port=MCP_PORT,
    streamable_http_path=MCP_PATH,
    json_response=MCP_JSON_RESPONSE,
    stateless_http=MCP_STATELESS,
)

# Cached bearer token populated by `login`.
_session: dict[str, Optional[str]] = {"auth_token": None, "username": None}


# --------------------------------------------------------------------------- #
# HTTP helper
# --------------------------------------------------------------------------- #

def _request(
    method: str,
    path: str,
    *,
    json_body: Optional[dict] = None,
    auth_token: Optional[str] = None,
    use_session_token: bool = False,
) -> dict[str, Any]:
    """Send a request to VAmPI and return a normalized result dict.

    Returns keys:
        status_code : int HTTP status
        ok          : bool (2xx)
        data        : parsed JSON (dict/list) when present, else None
        text        : raw response body (only when JSON parse fails / empty)
    """
    url = f"{BASE_URL}{path}"
    headers: dict[str, str] = {}

    token = auth_token if auth_token is not None else (
        _session.get("auth_token") if use_session_token else None
    )
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if json_body is not None:
        headers["Content-Type"] = "application/json"

    try:
        resp = httpx.request(
            method, url, json=json_body, headers=headers, timeout=TIMEOUT
        )
    except httpx.HTTPError as exc:
        return {
            "status_code": None,
            "ok": False,
            "data": None,
            "text": None,
            "error": f"Request to {url} failed: {exc}",
        }

    result: dict[str, Any] = {
        "status_code": resp.status_code,
        "ok": resp.is_success,
        "data": None,
        "text": None,
    }

    body = resp.content or b""
    if body.strip():
        try:
            result["data"] = resp.json()
        except ValueError:
            result["text"] = resp.text
    # 204 / empty body is normal for VAmPI email & password updates.
    return result


# --------------------------------------------------------------------------- #
# Meta / DB tools  (crAPI health/seed  ->  VAmPI home/createdb)
# --------------------------------------------------------------------------- #

@mcp.tool()
def home() -> dict[str, Any]:
    """GET / — VAmPI home/help banner. Confirms the API is reachable and whether
    it is running in vulnerable mode."""
    return _request("GET", "/")


@mcp.tool()
def create_db() -> dict[str, Any]:
    """GET /createdb — (Re)create and seed the VAmPI database with dummy data.
    Seeds users name1/pass1, name2/pass2, and admin/pass1 (admin), each owning a
    random book. Destroys any existing data."""
    return _request("GET", "/createdb")


# --------------------------------------------------------------------------- #
# User tools  (crAPI identity endpoints  ->  VAmPI /users/v1 + /me)
# --------------------------------------------------------------------------- #

@mcp.tool()
def get_all_users() -> dict[str, Any]:
    """GET /users/v1 — List all users with basic info (username, email)."""
    return _request("GET", "/users/v1")


@mcp.tool()
def debug_users() -> dict[str, Any]:
    """GET /users/v1/_debug — List ALL user details including passwords and admin
    flags. (Intentionally vulnerable debug endpoint.)"""
    return _request("GET", "/users/v1/_debug")


@mcp.tool()
def register_user(
    username: str,
    password: str,
    email: str,
    admin: bool = False,
) -> dict[str, Any]:
    """POST /users/v1/register — Register a new user.

    Args:
        username: desired username
        password: desired password
        email:    user email address
        admin:    request admin privileges (honored only in vulnerable mode)
    """
    body: dict[str, Any] = {"username": username, "password": password, "email": email}
    if admin:
        body["admin"] = True
    return _request("POST", "/users/v1/register", json_body=body)


@mcp.tool()
def login(username: str, password: str) -> dict[str, Any]:
    """POST /users/v1/login — Authenticate and cache the JWT for this session.

    On success the returned `auth_token` is stored and reused automatically by
    the authenticated tools (me, add_book, get_book_by_title, update_email,
    update_password, delete_user)."""
    result = _request(
        "POST",
        "/users/v1/login",
        json_body={"username": username, "password": password},
    )
    data = result.get("data") or {}
    token = data.get("auth_token") if isinstance(data, dict) else None
    if token:
        _session["auth_token"] = token
        _session["username"] = username
        result["session_token_set"] = True
    else:
        result["session_token_set"] = False
    return result


@mcp.tool()
def get_current_user(auth_token: Optional[str] = None) -> dict[str, Any]:
    """GET /me — Return the currently authenticated user's details. Uses the
    cached session token unless `auth_token` is supplied."""
    return _request("GET", "/me", auth_token=auth_token, use_session_token=True)


@mcp.tool()
def get_user_by_username(username: str) -> dict[str, Any]:
    """GET /users/v1/{username} — Retrieve a single user by username
    (public; no auth required)."""
    return _request("GET", f"/users/v1/{username}")


@mcp.tool()
def update_email(
    username: str,
    email: str,
    auth_token: Optional[str] = None,
) -> dict[str, Any]:
    """PUT /users/v1/{username}/email — Update the authenticated user's email.
    VAmPI returns HTTP 204 (empty body) on success. Requires auth."""
    return _request(
        "PUT",
        f"/users/v1/{username}/email",
        json_body={"email": email},
        auth_token=auth_token,
        use_session_token=True,
    )


@mcp.tool()
def update_password(
    username: str,
    password: str,
    auth_token: Optional[str] = None,
) -> dict[str, Any]:
    """PUT /users/v1/{username}/password — Update a user's password. Returns HTTP
    204 (empty body) on success. Requires auth. (In vulnerable mode this can
    update another user's password — BOLA.)"""
    return _request(
        "PUT",
        f"/users/v1/{username}/password",
        json_body={"password": password},
        auth_token=auth_token,
        use_session_token=True,
    )


@mcp.tool()
def delete_user(
    username: str,
    auth_token: Optional[str] = None,
) -> dict[str, Any]:
    """DELETE /users/v1/{username} — Delete a user by username. Admin token
    required; non-admins receive HTTP 401."""
    return _request(
        "DELETE",
        f"/users/v1/{username}",
        auth_token=auth_token,
        use_session_token=True,
    )


# --------------------------------------------------------------------------- #
# Book tools  (crAPI resource endpoints  ->  VAmPI /books/v1)
# --------------------------------------------------------------------------- #

@mcp.tool()
def get_all_books() -> dict[str, Any]:
    """GET /books/v1 — List all books (title + owning user)."""
    return _request("GET", "/books/v1")


@mcp.tool()
def add_book(
    book_title: str,
    secret: str,
    auth_token: Optional[str] = None,
) -> dict[str, Any]:
    """POST /books/v1 — Add a new book with a secret only the owner should read.
    Requires auth."""
    return _request(
        "POST",
        "/books/v1",
        json_body={"book_title": book_title, "secret": secret},
        auth_token=auth_token,
        use_session_token=True,
    )


@mcp.tool()
def get_book_by_title(
    book_title: str,
    auth_token: Optional[str] = None,
) -> dict[str, Any]:
    """GET /books/v1/{book_title} — Retrieve a book and its secret by title.
    Requires auth. (In vulnerable mode any authenticated user can read any
    book's secret — BOLA.)"""
    return _request(
        "GET",
        f"/books/v1/{book_title}",
        auth_token=auth_token,
        use_session_token=True,
    )


if __name__ == "__main__":
    mcp.run(transport=MCP_TRANSPORT)
