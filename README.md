# mcp-vampi
Get [vAmPI](https://github.com/erev0s/VAmPI) ready for agentification
## Why
Before you do most things, you should know why. In this case, it's to test APIs and in doing so, show that modern API Security tooling can detect when an MCP (Model Context Protocol) server has been deployed. This is important, because it's how APIs are being automated as agents. And if intended use cases can be automated, so can unintended ones...or chained together. Now that you know why, let's begin.
## How
The diagram below shows us how we've wired things together. We'll start from vAmPI (a Flask app) and ignore the components below it. Notice the mapping from REST to MCP starting at line 46 below. Notice how `/createdb` (REST-ified) becomes `populate_db` (MCPized). The MCP Server uses JSON RPC (Remote Procedure Call) to abstract & standardize the lower level implementation of RESTful interfaces.
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
║  Env: MCP_TRANSPORT=streamable-http  MCP_HOST=127.0.0.1  MCP_PORT=8009  ║
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
