# mcp-vampi
Get [vAmPI](https://github.com/erev0s/VAmPI) ready for agentification
## Shoulder of giant
Full credit belongs to [Michael Cropsey](https://github.com/mcropsey), who lead the way with [this](https://github.com/mcropsey/claude-crapi-mcp-remote-server-demo). Thank you sir! 🫡
## Why
Before you do most things, you should know why. In this case, it's to understand the implications of new API usage patterns and in doing so, show that modern API Security tooling must detect when an [MCP (Model Context Protocol)](https://modelcontextprotocol.io/specification/2025-11-25) server has been deployed. This is important, because it's how APIs are being automated as agents. And if intended use cases can be automated, so can unintended ones...or chained together. We'll first show the visibility problem and in future exercises, the additional consequences. Now that you know why, let's begin.
## Prerequisites
* We're assuming you know your way around a command line and Linux.
  ### Server side
* If not already there, install git and python311 (on RHEL, `sudo dnf install git python311`)
* Git clone this repo down and set it up so you can do the below.
* It assumes you've setup [vAmPI](https://github.com/erev0s/VAmPI) on another machine but w/in the same subnet.
* You'll also want [venv](https://docs.python.org/3/library/venv.html) prepped.
* [Install the requirements](
* Be gentle on yourself: `sudo chown -R $USER:$USER /opt/mcp-vampi`
  ### Client side
* A [Claude](https://claude.ai) account and Claude Desktop
* And [Node](https://nodejs.org/en/download)
## Usage
Here's an example CLI that'll get the server running. Handy b/c you can debug via STDOUT.
### Server side 
#### (streaming or stateful)
```
MCP_TRANSPORT=streamable-http \
MCP_HOST=0.0.0.0 \
MCP_PORT=80 \
MCP_PATH=/mcp \
VAMPI_BASE_URL=http://172.31.43.19:5000 \
VAMPI_TIMEOUT=30 \
/opt/mcp-vampi/.venv/bin/python /opt/mcp-vampi/server.py
```
#### (onesy twosy or stateless)
```
MCP_TRANSPORT=streamable-http \
MCP_HOST=0.0.0.0 \
MCP_PORT=80 \
MCP_PATH=/mcp \
MCP_STATELESS=true \
MCP_JSON_RESPONSE=true \
VAMPI_BASE_URL=http://172.31.43.19:5000 \
VAMPI_TIMEOUT=30 \
sudo /opt/mcp-vampi/.venv/bin/python /opt/mcp-vampi/server.py
```
NOTE: transport unintuitively stays streamable, but we've added MCP_STATELESS and MCP_JSON_RESPONSE and set them both to TRUE.
### Client (Claude Desktop) side
Into your MCP server stanza (screenshot towards bottom) in your Claude Desktop Developer Settings, add:
```
    "mcp-vampi": {
      "command": "/opt/homebrew/bin/npx",
      "args": ["-y", "mcp-remote", "http://<IP_MCP_SERVER>/mcp", "--allow-http"]
    }
```
## Overview and Background
The diagram below shows us how we've wired things together. We'll start from vAmPI (a Flask app) and ignore the components below it (database and models). Notice the mapping from REST to MCP starting near the top of the third box below. Notice how `/createdb` (REST-ified) becomes `populate_db` (MCPized). The MCP Server uses [JSON RPC (Remote Procedure Calls)](https://www.jsonrpc.org/specification) to abstract & standardize the lower level implementation of RESTful interfaces. By taking this step, MCP enables [LLM agents](https://medium.com/@lekeonilude/the-role-of-mcp-in-llm-agents-cff9fc5fa96c) to use a single repeatable structure to call most popular APIs out there today.
```
┌─────────────────────────────────────────────────────────────────────┐
│  MCP CLIENT   (Claude Code / LLM agent)                             │
└─────────────────────────────────────────────────────────────────────┘
                │
                │  MCP · Streamable HTTP
                │  POST http://3.19.71.128:8009/mcp
                ▼
╔═════════════════════════════════════════════════════════════════════════╗
║  systemd unit:  vampi-mcp.service                                       ║
║  User/Group=vampimcp   WorkingDirectory=/opt/vampi-mcp                  ║
║  ExecStart=/opt/vampi-mcp/.venv/bin/python server.py                    ║
║  Restart=on-failure · hardening: NoNewPrivileges, ProtectSystem=strict… ║
║  Env: MCP_TRANSPORT=streamable-http  MCP_HOST=0.0.0.0  MCP_PORT=8009  ║
║       MCP_PATH=/mcp   VAMPI_BASE_URL=…:5000   VAMPI_TIMEOUT=30          ║
║                                                                         ║
║   ┌────────────────────────────────────────────────────────────────┐    ║
║   │  VAmPI MCP Server   FastMCP("vampi")   [server.py]             │    ║
║   │                                                                │    ║
║   │  _session { auth_token, username }   ← cached by login()       │    ║
║   │  _request()  →  httpx.request(...)   ← attaches Bearer token   │    ║
║   │                                                                │    ║
║   │  @mcp.tool() (14):                                             │    ║
║   │    home  create_db                                             │    ║
║   │    get_all_users  debug_users  register_user  login            │    ║
║   │    get_current_user  get_user_by_username                      │    ║
║   │    update_email  update_password  delete_user                  │    ║
║   │    get_all_books  add_book  get_book_by_title                  │    ║
║   └────────────────────────────────────────────────────────────────┘    ║
╚═════════════════════════════════════════════════════════════════════════╝
                │
                │  HTTP (httpx) · Authorization: Bearer <JWT>
                │  VAMPI_BASE_URL = http://172.31.43.19:5000
                ▼
┌────────────────────────────────────────────────────────────────────────┐
│  VAmPI Flask API   vuln_app · 0.0.0.0:5000 · debug=True   [app.py]     │
│  flags:  vuln = $vulnerable (default 1)   alive = $tokentimetolive(60) │
│                                                                        │
│  ROUTES         RAW RESTful                    MCP Wrapper             │
│────────────────────────────────────────────────────────────────────────| 
│   main.py    GET    /                      basic()  (banner+vuln flag) │
│              GET    /createdb              populate_db()  drop + seed  │
│                                                                        │
│   users.py   GET    /users/v1             get_all_users                │
│   (api_      GET    /users/v1/_debug      debug         ⚠ dumps pw/adm │
│    views)    GET    /me                   me            (JWT)          │
│              GET    /users/v1/{user}      get_by_username ⚠ SQLi       │
│              POST   /users/v1/register    register_user ⚠ mass-assign  │
│              POST   /users/v1/login       login_user    ⚠ user/pw enum │
│              PUT    /users/v1/{u}/email   update_email  ⚠ ReDoS        │
│              PUT    /users/v1/{u}/password update_password ⚠ BOLA      │
│              DELETE /users/v1/{user}      delete_user   (admin only)   │
│                                                                        │
│   books.py   GET    /books/v1             get_all_books                │
│              POST   /books/v1             add_new_book  (JWT)          │
│              GET    /books/v1/{title}     get_by_title  ⚠ BOLA         │
│                                                                        │
│  json_schemas.py — body validation (register / login / email / book)   │
│  JWT — HS256 w/ SECRET_KEY; encode/decode in user_model                │
└────────────────────────────────────────────────────────────────────────┘
                │
                │  SQLAlchemy ORM  (db from config)
                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  MODELS                                                             │
│   user_model.User                                                   │
│     users( id, username, password, email, admin )                   │
│        │ 1                                                          │
│        │                                                            │
│        │ *   relationship  user ◄──► books                          │
│   books_model.Book                                                  │
│     books( id, book_title, secret_content, user_id → users.id )     │
└─────────────────────────────────────────────────────────────────────┘
                │
                ▼
┌───────────────────────────────────────────────────────────────────────┐
│  DATABASE   (config.db SQLAlchemy engine — SQLite by VAmPI default)   │
│  seeded by /createdb → name1/pass1, name2/pass2, admin/pass1 (admin)  │
└───────────────────────────────────────────────────────────────────────┘
```
## Screenshots and the goal
<img width="480" height="355" alt="image" src="https://github.com/user-attachments/assets/ac652542-5da9-4607-a63d-f30ffb60771f" />
<br><br>
When you've everything wired up, you can run API commands in plain English!

<img width="600" height="400" alt="image" src="https://github.com/user-attachments/assets/152bbfec-645e-414a-892f-ba149d12e58d" />

## Debugging
When you need to diagnose something, after asking Claude, lean into STDOUT for the server, [curl](https://curl.se/) or [httpie](https://httpie.io/) for the client commands. Here are a couple representative commands to get you started. The rest are deriveable from the [OAS](https://github.com/erev0s/VAmPI/blob/master/openapi_specs/openapi3.yml) or the [Postman Collection](https://github.com/erev0s/VAmPI/blob/master/openapi_specs/VAmPI.postman_collection.json):

#### populate the db
request: `curl 18.191.213.77:5000/createdb`
<br>
response: `{ "message": "Database populated." }`
#### login
req: `http 18.191.213.77:5000/users/v1/login password=pass2 username=name2`
<br>
res: 
```
{
    "auth_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3ODEzOTg3MDcsImlhdCI6MTc4MTM5ODY0Nywic3ViIjoibmFtZTIifQ._fErlNo3Jl-suPj1yvjjfQgyoaAq9lITcD1zY3iXYJM",
    "message": "Successfully logged in.",
    "status": "success"                                                                  
}
```
