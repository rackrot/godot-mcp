# Godot MCP addon v1: the editor is the MCP server

## Goal

A Godot 4.7 editor plugin, `addons/godot_mcp/`, written in GDScript, that **is** the MCP server. It serves Streamable HTTP at `http://127.0.0.1:<port>/mcp`, and Claude Code connects to it directly. It is the only shipped product. Installing it means copying the folder (or using the Asset Library) and enabling the plugin; the plugin sets itself up. It gives agents:

- live editor state: project info and settings, the scene tree, opening, creating and saving scenes, node CRUD and properties on the editor's undo history, script read/create/edit/validate, the editor log, play and stop
- headless jobs without leaving the editor: asset import (an in-editor rescan), headless scene or script runs with parsed diagnostics, and later a gated .NET build

`addons/godot_mcp/SKILL.md` teaches agents to use it. The plugin installs it into the project's `.claude/skills/`, and a short version goes out as `instructions` in `InitializeResult`.

This replaces v0 entirely. The v0 Bun server (slices 1–2) is retired once the addon reaches parity (slice 9). Its TypeScript test harness stays as a dev-only conformance lane.

## Definition of done

- [ ] `bun run check` passes, including `tests/editor/*`, which drive a real `godot-mono --headless --editor` (4.7.2). A missing binary fails the run; it never skips.
- [ ] Conformance: `@modelcontextprotocol/client` 2.3.1 `StreamableHTTPClientTransport` connects in its default mode (`legacy`) and with `versionNegotiation: {mode: "auto"}`, lists tools, calls them, and raises no `onerror`.
- [ ] Parity: `get_project_info`, `import_assets` and `run_headless` cover `godot_project_info`, `godot_import` and `godot_run`, including every v0 slice 2 acceptance criterion ported in slice 5. The TS server is then retired (slice 9).
- [ ] Operator: copy the addon into `lagrange-protocol` and enable it, run Project > Tools > "MCP: install agent skill / show config", paste the entry into `.mcp.json`, accept the trust dialog. `claude mcp list` then shows `godot-editor` connected. Repeat once with `MCP_PROTOCOL_NEGOTIATION=auto` (A10).
- [ ] Operator GUI smoke test, once: the agent adds a node, the user presses Ctrl+Z and the node is gone, then redo, save, `play_scene`, and the menu item's dialog with its Copy button.
- [ ] SKILL.md passes the `authoring:create-skill` checks and names every tool `tools/list` returns.
- [ ] `build_dotnet` e2e (unblocked: .NET SDK 10.0.112 and runtime 10.0.12 installed): `tests/editor/build.test.ts` runs the fake-dotnet cases and the real build of `fixtures/cs`.

## Verified facts the plan relies on

| Fact | Source |
|---|---|
| The current MCP revision is **2026-07-28**. It removed `initialize`, protocol sessions and the GET stream, and added `server/discover` and per-request `_meta` versioning. 2025-11-25 and earlier are "legacy". Legacy is **not** deprecated. | modelcontextprotocol.io `/specification/versioning`, `/2026-07-28/changelog`, `/2026-07-28/deprecated` |
| 2025-11-25 Streamable HTTP: one message per POST. Notifications and client responses get 202 with no body. A request gets JSON or SSE. GET must open SSE or return 405. A present but invalid Origin gets 403. `MCP-Protocol-Version` is sent after `initialize`; a missing header means 2025-03-26, an invalid one gets 400. Session IDs are optional. | `/specification/2025-11-25/basic/transports` |
| SDK client 2.3.1 defaults to `'legacy'`. In `'auto'` mode it probes `server/discover` with `MCP-Protocol-Version: 2026-07-28`. Any error other than -32022, and any 4xx below 500 except 401/403, falls back to legacy. 401, 403 and 5xx are hard errors. | `node_modules/@modelcontextprotocol/client/dist/index.mjs:2396-2507`; codex reproduced both modes in memory |
| After `notifications/initialized` gets a 202, the client opens a GET and quietly accepts only 405. It sends no DELETE without a session ID. It requires a JSON or SSE `Content-Type`. Its default request timeout is 60 s. | `index.mjs:5485-5553, 5795-5815, 5836`; `src-*.mjs` `DEFAULT_REQUEST_TIMEOUT_MSEC = 6e4` |
| Claude Code 2.1.300: the v2 runtime probes for 2026-07-28 and otherwise connects as v1. `MCP_PROTOCOL_NEGOTIATION=auto\|legacy` overrides this. | code.claude.com/docs/en/mcp "MCP client runtimes" |
| `.mcp.json` http entries take `type`, `url`, `headers`, `headersHelper` and `timeout`. `headersHelper` runs in a shell on each connect and is re-run once after a 401 or 403. Its cwd is the project dir. It runs only after the trust dialog. | code.claude.com/docs/en/mcp "Use dynamic headers" |
| For HTTP servers, Claude Code also runs a **timer to the first response byte** of max(60 s, the server's `timeout`, `MCP_TIMEOUT`). `timeout` is the per-call wall clock. Progress notifications don't extend either timer. | code.claude.com/docs/en/mcp (tool timeouts) |
| Claude Code cuts instructions at 4,096 characters. A nested `<subdir>/.claude/skills/<name>/SKILL.md` loads once Claude works on files in that subdirectory. | code.claude.com/docs/en/mcp; code.claude.com/docs/en/skills "monorepos and subdirectories" |
| Godot 4.7.2 has no HTTP server class. `TCPServer.listen(port, bind="*")`. `StreamPeerTCP` inherits `StreamPeerSocket`. `get_partial_data` doesn't block; `put_data` blocks; `put_partial_data` returns the count sent. | 4.7.2 doctool dump; `doc/classes/{TCPServer,SocketServer,StreamPeerSocket,StreamPeer}.xml` |
| `OS.execute_with_pipe(path, arguments, blocking=true) -> {stdio: FileAccess, stderr: FileAccess, pid}`, or `{}` on failure. With `blocking=false` the pipes are `O_NONBLOCK`. It has **no env and no cwd parameter**; the child inherits both from the editor. | 4.7.2 `OS.xml`; `drivers/unix/os_unix.cpp:715-822`, `file_access_unix_pipe.cpp:61` |
| The pipe's `get_length()` returns the bytes ready (`ioctl FIONREAD`). `get_buffer` makes one `read()` and flags a short read as `ERR_FILE_CANT_READ`. | `file_access_unix_pipe.cpp:140-163` |
| An `execute_with_pipe` child calls **`setsid()`**, so it leads its own process group (pgid == pid). `create_process` does the same. | `os_unix.cpp:768, 968` |
| `OS.kill(int)` maps to `::kill(p, SIGKILL)` with no pid validation, then a blocking `waitpid(p)` to reap. So `OS.kill(-pid)` sends SIGKILL to the group. After a kill, `is_process_running(pid)` hits ECHILD and logs an error. | `core/core_bind.cpp:466`; `os_unix.cpp:1000-1008, 845-864` |
| `is_process_running` and `get_process_exit_code` work for pids from `execute_with_pipe` (`process_map`). | `os_unix.cpp:811-813, 1014-1029` |
| `OS.set_environment` changes the editor process's own environment, which children inherit. | 4.7.2 `OS.xml` |
| `EditorPlugin.add_tool_menu_item(name, callable)` adds to Project > Tools; `remove_tool_menu_item` removes it. | 4.7.2 `EditorPlugin.xml` |
| `application/run/flush_stdout_on_print` exists. stderr is always flushed per line. | 4.7.2 `ProjectSettings.xml` |
| `FileAccess.set_unix_permissions` is implemented on Linux/BSD, macOS and iOS. `Logger._log_*` is called off the main thread. `OS.get_cmdline_args` excludes engine args. | 4.7.2 `FileAccess.xml`, `Logger.xml`, `OS.xml` |
| `EditorInterface.save_scene()` returns OK even when the write fails. | `editor/editor_interface.cpp:763-773` |
| Scene switching after `open_scene_from_path` is asynchronous. | godot_ai `handlers/scene_handler.gd:195-250` |
| `remove_child` nulls the owners of descendants. `reparent` documents owner preservation only for the node itself. | 4.7.2 `Node.xml` |
| `str_to_var` instantiates `Object(...)` and loads `Resource(...)` while parsing. | `core/variant/variant_parser.cpp:995-1170` |
| `EditorFileSystem.reimport_files` blocks but runs `_process`. `scan()`, `is_scanning()` and the `resources_reimported`/`filesystem_changed` signals exist. | 4.7.2 `EditorFileSystem.xml` |
| `ScriptEditor.get_unsaved_files/reload_open_files/close_file`. `EditorUndoRedoManager` has no bound `undo()`. `Crypto.constant_time_compare`, `DirAccess.is_link`, `PackedScene.GEN_EDIT_STATE_INSTANCE` all exist. | 4.7.2 doctool dump |
| `godot --check-only --script` exists. `editor/run/main_run_args` appends args to play-scene runs. | `godot-mono --help`; `ProjectSettings.xml` |
| The godot-mcp-pro public README lists 187 tools and says "Proprietary". Only its names and groups are used. | GitHub API `repos/youichi-uda/godot-mcp-pro/readme` |

Assumptions still to verify:

- A1: `--headless --editor` loads plugins and runs `_process`. Slice 1, step 1, with stop-and-report.
- A7: **confirmed in slice 4.** `ResourceLoader.load(path, "", CACHE_MODE_IGNORE)` on a script with a parse or compile error reaches `Logger._log_error` for the first error only (GDScript stops at the first) with `file` = the script path, `function` = `GDScript::reload`, the 1-based `line`, and a `Parse Error: ...` message (the editor also prints `SCRIPT ERROR:` and `at: GDScript::reload (res://x.gd:N)`). A second entry from `gdscript_resource_format.cpp` (`Failed to load script ... Parse error`) has a different `file` and is dropped. `lineUnknown` stays as the fallback for a failed load that logs nothing. GDScript **warnings** (unused variable and the like) reach only the debugger, never the Logger, so they are not reported.
- A9: open, save and play work headless. **Open and save confirmed in slice 1** (open 7 ms, open→edit→save 18 ms). A headless save logs `ERROR: Parameter "t" is null … texture_2d_get` from the dummy renderer's thumbnail step; slice 3's save Logger capture must ignore it. Play is still pending (slice 3).
- A10: Claude Code's bundled classifier matches SDK 2.3.1. Operator check.
- A11: **confirmed in slice 1, pinned in slice 2** (`read-tools.test.ts`): a fresh headless editor auto-opens the main scene. The `NO_SCENE` test starts a second editor on a copy with `run/main_scene` removed.
- Slice 2 findings: `OS.add_logger` receives the editor's progress lines, ANSI escapes included. `JSON.stringify` escapes `\b\t\n\f\r`, emits the invalid `\v` for U+000B, and leaves other control characters raw, so `mcp_server.gd` rewrites those as `\u00XX` (escape-aware, so a literal backslash-v survives). Godot treats `\` as a path separator after validation runs on the raw text, so `res_paths.gd` rejects backslashes and colons and requires `simplify_path() == path`. A GDScript function with a typed return (`-> Dictionary`) that hits a runtime error returns the empty default, so tool handlers return `Variant` and null means failure. A null Object property has `typeof == TYPE_OBJECT`. `name` has no `PROPERTY_USAGE_EDITOR`. The editor refuses to open a scene with a missing dependency (`broken_ref.tscn`), so `open_scene` ends in `SCENE_SWITCH_TIMEOUT` after 10 s and the missing resource is in the log. On this host `tcp_rmem` max is 100 MB, so a reply at the 4 MB cap never stalls; the write deadline is proven in `dispatch.test.ts` with a 48 MB reply.
- Slice 3 findings (`mutations.test.ts`): **A9 for play is confirmed**: with `editor/run/main_run_args="--headless"`, `play_scene` starts the game and `playingScene` toggles with `stop_scene`. A headless `save_scene` logs `ERROR` from `texture_2d_get` (`Parameter "t" is null.`) on every save; `save_scene` ignores exactly that entry and fails on any other error since the call began. `EditorInterface.save_scene()` replaces a read-only file through its temp-and-rename save, so `save_scene` checks the owner write bit itself; a read-only directory fails in the editor and shows in the log. A `<path>.remap` makes the editor load the remap target under `<path>`, so a save would overwrite the original with it; creation is not redirected. `res_paths.gd` refuses any path with a sibling `.remap`. Undo and redo of add, delete and move restore descendant owners (checked once with a throwaway provider that called the history's `undo()`; it is not in the suite). The input codec cannot merge `{1: a, "1": b}`, since JSON object keys are all strings; the output side (`value_codec.gd`) still can.
- Slice 4 findings (`scripts.test.ts`): `get_unsaved_files` lists `res://` paths in Godot master's source (the 4.7.2 tag was not read); the headless editor has no script tab, so `unsavedInEditor: true` and the dirty-buffer refusal are code review only. The diagnostics load (`CACHE_MODE_IGNORE`) reloads an already cached Script in place, which is why a later `update_property script=` sees the new source with no separate refresh (checked). That in-place reload is also why `validate_script res://addons/godot_mcp/...` crashed the editor (SIGSEGV: the reloaded Script had functions on the call stack), so `validate_script` refuses that directory. A leading UTF-8 BOM is stripped from `content` and written back by `edit_script`. A failed write restores the original bytes (edit) or removes the partial file (create), because the editor's save renames its temp file on close without checking write errors; this path is untested, since a full disk is hard to fake. `oldText` is capped at 64 KB. A `.cs` file is readable but not writable or validatable. Script reads and writes are capped at 1 MB, and a file that is not valid UTF-8 gives `NOT_UTF8` so an edit never rewrites bytes it did not touch. `main_scene` and autoload values may be `uid://`; `ResourceUID` resolves them and the resolved path gets the usual extension check. An empty `get_unsaved_scenes()` entry for an untitled scene is UNCONFIRMED; `play_scene` skips `""` either way. Three v0 tests in `tests/godot/run.test.ts` fail while a GUI Godot editor holds the language-server port 6005 (`!thread.is_started()` on `--import`); they fail the same way at slice 3. Fixed later: `importArgs` passes `--lsp-port 0`, so the import never binds the port.
- A12: **confirmed in slice 5.** `OS.kill(-pid)` returns OK and kills the child's whole group: a `sh` child's `sleep` grandchild (same group, pgid == the child's pid) was gone 100 ms later, and `/proc/<pid>` was gone. The job tools never ask about the pid afterwards, and the logs show no ECHILD noise. `jobs.test.ts` keeps this as a regression: `hang_group.gd` starts a background `sleep` through `OS.execute` (which does not `setsid`, unlike `execute_with_pipe` and `create_process`), and a timeout kills it.
- A13: **confirmed in slice 5.** On a non-blocking `execute_with_pipe` pipe, `get_length()` followed by `get_buffer(n)` returns exactly the ready bytes with `get_error() == OK`; a character split across two reads arrives whole after the reads are concatenated. `FileAccess.open("/dev/stderr", ...)` fails in every mode (`ERR_FILE_CANT_OPEN`), so `split_line.gd` writes its pieces from `create_process("/bin/sh")`, which inherits the game's stderr. `OS.execute` hides a child's stderr instead.
- A14: **refined in slice 5.** `scan()` does reimport changed sources, but `is_scanning()` goes false when the scan thread ends, before the reimport has run (a `.ctex` appeared only after `import_assets` had returned). In 4.7.2 (`editor_file_system.cpp`) the main-thread process step then runs the reimport synchronously and emits `filesystem_changed`; `is_importing()` is true inside it. So `import_assets` waits for a running scan and import (`is_scanning() or is_importing()`), connects to the signal, calls `scan()` (asking again, up to 5 frames, while the call itself neither set `is_scanning()` nor emitted the signal; the flag is cleared before each call, because the old scan's own `filesystem_changed` can fire in the same frame and `scan()` no-ops while the old thread is still collected), and waits for the signal with the editor idle. The job runner probes `timeout --version`, so busybox `timeout` (no `--version`) gets SPAWN_FAILED even where `-k` would work. `get_project_info.scanning` covers both too. 200 small SVGs import in about 40 ms. A second import with nothing changed also emits it and returns at once. An unreadable PNG logs one `WARNING: Not a PNG file` and `ERROR` entries naming `res://broken.png`, which the tool reports as diagnostics.
- A15: **confirmed in slice 5.** A headless `run_headless` child (`--headless --path P`, no `--editor`) changes nothing under `.godot/` (a content-hash snapshot excluding `godot_mcp/` is equal before and after a 30-frame run), so it doesn't race the editor's own writes. Caveat: the game's `user://` data is outside `.godot/` and untouched by this check.
- Slice 5 findings (`jobs.test.ts`, `parser.test.ts`):
  - **Cancel (D37, D33).** The SDK 2.3.1 client does not abort the in-flight POST on an `AbortSignal`; it sends `notifications/cancelled` on a new connection. The transport handles that notification at ingress, outside the FIFO (it touches no editor state), so it also stops an `import_assets` (which then stops waiting and reports `CANCELLED`; the editor's scan carries on). Requests register their JSON-RPC id when queued, not when started. A cancel applies only when exactly one request is in flight under the id and none finished under it in the last 60 s (a stale cancel must not hit another client's new request); otherwise it cancels nothing. The server is stateless, so any token holder can cancel any job; that is accepted under D33. A dropped connection cancels its request too.
  - **FIFO queueing (D46).** `PROJECT_BUSY` applies to jobs only once a job tool is dispatched. Other FIFO-bound tools queue behind a running `import_assets` and get a 500 at the 30 s default budget; `run_headless` releases the FIFO, so they don't queue behind it.
  - **Orphans.** `SIGTERM` and `SIGINT` kill the headless editor without running `_exit_tree`. `Plugin._exit_tree` kills the job child on a normal quit (the test quits the editor through a `@tool` static initializer). Every job child runs under coreutils `timeout -k 5 <timeoutSec + 60>`, which leads the child's group, so a killed editor leaves the child alive for at most `timeoutSec + 65 s`. `timeout` must be on PATH or the job fails with `SPAWN_FAILED` (no unwrapped fallback); macOS has none and stays UNCONFIRMED. After a normal exit the runner also kills the group, so a leftover background process dies as it did in v0.
  - **Exit codes and stdin.** Godot reports a signal-killed child's signal number as its exit code (`kill -9` and `exit 9` both give 9; `timeout` re-raises the child's signal), so v0's `exitCode: null` for a signal death is not available; `ok` is false either way. The child's stdin is the write side of the same pipe object as its stdout, which cannot be half-closed, so a game that reads stdin waits for the timeout.
  - **Parser caps.** Godot logs one error per invalid UTF-8 byte, so `output_parser.gd` validates bytes itself and decodes invalid ones as `?`. Line numbers are at most 9 digits (a longer run made `int()` log an error per line). A line is cut at 1,000 characters, a stack keeps 10 frames, and the first 64 KB of a newline-free run count as one line while the rest is skipped to the next newline. One text budget of 120,000 characters covers all kept diagnostic text. A reply carries its result twice (structured and as text), and a control character costs up to 13 bytes across both copies, so 120,000 characters plus two 64 KB tails stay under the 4 MB cap; text past the budget is dropped but counted, and `truncated` is set. `import_assets` counts errors from the log's running totals and sets `truncated` when the 1,000-entry ring evicted entries (`save_scene` and the script diagnostics fail safe the same way). The read-back after `close()` in `script_tools.gd` (`_store`) has no test seam: every tool path refuses a link or a special file, and a full disk can't be faked.
- A16: Godot ignores `addons/godot_mcp/SKILL.md` (no importer, no errors). Slice 7.
- Editor low-processor sleep defaults: **UNCONFIRMED**. Slice 1 measures them.

## Decisions

| # | Decision | Why | Rejected |
|---|---|---|---|
| D24 | **The addon is the MCP endpoint**, at `POST /mcp` on 127.0.0.1. | One process. The editor outlives sessions, and many sessions share one stateless endpoint. | v0 D16 bridge; the reference's Node ↔ WS ↔ plugin design |
| D25 | **Protocol era: 2025-11-25, served statelessly.** Supported versions are `2025-11-25`, `2025-06-18` and `2025-03-26`. No `Mcp-Session-Id`. JSON responses only. An array body gets 400 with -32600. An unsupported `MCP-Protocol-Version` gets 400 with -32600 and the supported list; the `auto` probe falls back that way. `server/discover` and other unknown methods, with a legacy or missing header, get 200 with -32601. | Works with Claude Code v1 and v2 and with the SDK default. Smallest surface. | Modern-only: breaks v1 and the SDK default. Dual-era now: no client needs it (open question 9). |
| D26 | **GDScript**, not C#. | C# would make editor tests depend on dotnet, which is blocked. | C# |
| D27 | **An HTTP/1.1 subset of our own**, polled in `_process`. Framing is `Content-Length` only (411 otherwise). `Connection: close` on every response. Writes go through a non-blocking outbound buffer (`put_partial_data`) with a write deadline. | No HTTP server exists in Godot. A client that stops reading can't freeze the editor. | Keep-alive, chunked bodies, SSE, blocking `put_data`, a worker thread |
| D28 | **Guards, in this order:** Host must be `127.0.0.1\|localhost:<port>` (403); Origin may be absent, and a present one must be `http://127.0.0.1\|localhost:<port>` (403); path `/mcp` (404); method POST (405, `Allow: POST`, before auth); bearer token checked in constant time (401 with `WWW-Authenticate: Bearer`); `application/json` (415); size (413). | DNS-rebinding guard; the spec's Origin rule; the client's GET always gets 405 | Rejecting a missing Origin; running without a token |
| D29 | **Token file.** 32 random bytes, hex, new on every server start. Published as `.godot/godot_mcp/headers.json` = `{"Authorization":"Bearer <hex>"}`: refuse links, write a `.tmp` with chmod 0600 before content, then `rename_absolute`. If chmod fails, the server doesn't start. The client config is `"headersHelper": "cat '<abs>/.godot/godot_mcp/headers.json'"`, shell-quoted. | The helper re-runs on each connect and after a 401, so a restart heals itself, and the helper never sees half a file. | A static token in `.mcp.json`; `${VAR}`; v0's ephemeral port plus discovery file |
| D30 | **A fixed port per project**, from `godot_mcp/server/port`. On first load, if the setting is missing, the plugin tries 6550–6649, saves the first free port, and never scans again. Saving goes through `ProjectSettings.save()`, which rewrites `project.godot` in Godot's normalized form, as any editor settings save does (accepted after the slice 1 review). If `listen` fails later, it prints one error line, writes no token, and doesn't scan. | `url` in `.mcp.json` is static. A second editor on the same project fails cleanly and leaves the first one's token alone. | Scanning on every start (the URL can't follow); one global fixed default (two open projects would collide) |
| D31 | **One server, one `.mcp.json` entry, `godot-editor`.** The headless tools live in the addon (D44). Every tool therefore needs a running editor. Headless agents or CI run `godot --headless --editor --path P` as a service, which is exactly what the test lane does. | One product, one install, one auth path | Keeping the Bun stdio server alongside (the earlier D31). Merging later was the old plan. |
| D32 | **24 tools** (table below), reference snake_case names without a prefix. | 187 is the anti-pattern | The reference's groups beyond core |
| D33 | **No dedicated execute-GDScript tool, but the script writers execute code (see slice 4 below), so the bearer token is the security boundary.** This is **not a sandbox**: validation runs static initializers of `@tool` scripts, attaching runs `@tool` code, setters run script code, `open_scene` runs `@tool` scripts in the scenes it loads and `get_node_properties` runs script getters (both despite `readOnlyHint`), and `run_headless` runs the game. Slice 3 adds more code-running surfaces: `set_project_setting` (autoloads and the main scene run at game start), Object-property loads (`update_property`, `add_node` properties; the type is checked from the file index before loading, but an accepted script or resource still loads), and `add_node {scene}` instancing. `set_project_setting` refuses `editor/`, `editor_plugins/` and `godot_mcp/`, since `editor/run/main_run_args` is the play-mode command line. `move_node` and a rename do not update NodePath properties or signal connections that point at the node. **Slice 4, script writers: the bearer token is the only security boundary.** `create_script` and `edit_script` stay always on, with no gate. One `edit_script` call with a `@tool` script and a `_static_init` runs arbitrary code in the editor, because the writer's own diagnostics load runs the static initializers of @tool scripts (confirmed live; it wrote into `addons/godot_mcp/`). Static initializers of scripts that are not @tool do not run on create or validate. Further channels: `validate_script` and the writers' diagnostics reload the live cached Script in place, so open scenes, autoloads and @tool instances that use it pick up the change at once; `reload_open_files` reloads open script tabs; and an edited EditorPlugin script runs on the next enable or editor restart. `PROTECTED_PATH` (writes and validation under `res://addons/godot_mcp/`, any case) guards against accidental edits of the server's own files and against a crash (validating them reloads Scripts whose functions are on the stack, SIGSEGV); it is **not** a security boundary. Its case-folding is untested off Linux; Windows 8.3 names and Unicode folding are UNCONFIRMED and not hardened. A planted `.claude/skills/*/SKILL.md` (from a clone, or an earlier install) keeps steering later Claude Code sessions after the token rotates, since the skill outlives the server's token. | Honest threat model | Calling the exclusion a sandbox |
| D34 | **Scene-tree edits** go through `get_undo_redo()`, one `MCP: <verb> <node>` action per call, and results report `undoAction`. Structural edits apply only to nodes the root owns, with a subtree owner map reapplied in do and undo. Disk writes are not undoable. There is **no `undo` tool**. | `remove_child` nulls descendant owners | An `undo` tool: no bound manager `undo()`. Recursive `set_owner(root)`. |
| D35 | **Value codec.** Output is `{type, value}`: primitives, String, StringName and NodePath native; a Resource becomes `resource_path` or null plus `class`; containers with primitive leaves are JSON; anything else goes through `var_to_str`. Input is checked against the declared type. An Object property takes a validated `res://` path or null. Math and packed numeric types take a literal that must match a whitelist regex before `str_to_var`, with `typeof` checked after. Containers take JSON with primitive leaves. Every other type gets `UNSUPPORTED_TYPE`. | Safe and symmetric (`variant_parser.cpp:995-1170`) | A blacklist; godot_ai's output-only serializer; smart parsing |
| D36 | **Results** carry `structuredContent` plus a JSON text block, no `outputSchema`. A tool failure returns `isError` with `{error: {code, message}}`; bad params get -32602. GDScript dict schemas feed `tools/list` and a small validator. | The SDK client validates against `outputSchema` | Per-tool output schemas |
| D37 | **Dispatcher.** Handlers may be coroutines. Editor-state requests run one at a time from a FIFO, and re-entrant `_process` keeps doing I/O but starts no dispatch. Executing peers are pinned. The 5 s ingress deadline is separate from an execution budget of 30 s by default, or `timeoutSec + 10 s` for jobs. `open_scene` waits until the switch settles. Coroutines check `is_instance_valid` after each `await`. **Resolved in slice 2:** each request carries a `Request` token (`request.gd`). When the budget expires or the peer closes, the transport sets `cancelled` but keeps the FIFO until the handler returns; awaiting handlers use `request.next_frame()` and return once it gives false, so two editor-state handlers never overlap. A handler that never resumes holds the FIFO. Handlers are `func(arguments, request) -> Variant`; null is `INTERNAL` and an empty Dictionary is a result. **Job tools** (`run_headless`, `build_dotnet`) run **outside** the FIFO once spawned, since they touch only their own child. | Async scene switches, re-entrancy, and long runs that don't stall other tools | A plain `_dispatching` flag; long jobs that hold the FIFO |
| D38 | **Paths** (v0 D11). Inputs are `res://`, no `..`, nothing under `res://.godot/`, a per-tool extension allowlist, no link components. Reads require the target; creates refuse an existing one. `run_headless` user args go only after `--`. | Trust boundary | |
| D39 | **SKILL.md** ships at `addons/godot_mcp/SKILL.md`. The plugin installs it (D40). `instructions` is a constant of at most 2,000 characters. | | Generating instructions from Markdown at runtime |
| D40 | **The plugin sets itself up; no external installer.** Install = copy `addons/godot_mcp/` or use the Asset Library, then enable. In `_enter_tree` the plugin ensures the port (D30), writes `.godot/godot_mcp/.gitignore` (`*`), and starts the server. Project > Tools > "MCP: install agent skill / show config" and the tool `install_agent_skill` share one code path (`setup.gd`). It writes `<project>/.claude/skills/godot-mcp/SKILL.md` and returns or shows the ready `.mcp.json` entry (url, shell-quoted `headersHelper`, `timeout`) in a dialog with a Copy button. **Safety:** refuse if `.claude`, `skills`, `godot-mcp` or `SKILL.md` is a link; idempotent (byte-equal means `changed: false`); refuse an existing SKILL.md without our marker unless `overwrite`, where the marker is the line `  godot_mcp: "true"` under `metadata:` in the frontmatter (the block between the first two `---` lines; a string, since the Agent Skills spec makes `metadata` a string map) and a SKILL.md that has it is replaced without `overwrite`; touch no other file; **never write `.mcp.json`**; write the port only when it is missing and touch no other setting. **Implemented:** setup never writes the port, since startup already saved it (D30), and `Setup` takes the port the server bound (0 until the publish succeeds, so `NOT_LISTENING`). The menu shows the entry even when the skill install fails (the entry is the part that connects); a refused `${` or control character in the path, and Windows (`UNSUPPORTED_PLATFORM`, POSIX-only, D29), show no entry and no helper. | Zero-dependency install. The tool makes setup testable from TS, since headless menus can't be clicked, and lets agents refresh the skill after an upgrade. | `godot_addon_install` in Bun (old D40 and slice 6); menu only (untestable) |
| D41 | **Test lane** (dev-only, TS). Copy `fixtures/gd` to a temp dir, add the addon, enable it, set a free port and `editor/run/main_run_args="--headless"`, then spawn `godot-mono --headless --editor` in its own process group. Poll until 401, read `headers.json`, and drive with the SDK client, `fetch` and `node:net`. One editor per test file. The harness may set `PATH` for the editor, so fakes such as `fake-dotnet.sh` resolve. | Tests run against the real editor | GUT |
| D42 | **Reuse.** The godot-mcp-pro README is the only input (names and groups); everything is written from scratch. godot_ai (MIT) may be read for patterns. | Paid and proprietary | Adapting its code |
| D43 | **A GDScript editor addon, not a native GDExtension.** | No per-platform binaries, toolchain or ABI coupling to Godot minor versions; easy Asset Library packaging. GDScript is fast enough for loopback JSON. | A C++ or Rust GDExtension: real threads and HTTP libraries, but builds per OS and arch, plus heavier release work |
| D44 | **Headless jobs inside the addon.** `import_assets` runs `EditorFileSystem.scan()` and awaits until `!is_scanning()`, capturing Logger errors meanwhile; it is exclusive in the FIFO. `run_headless` spawns `OS.execute_with_pipe(OS.get_executable_path(), ["--headless", "--path", <abs>, (<res scene> \| "-s", <res script>), ("--quit-after", N)?, "--", userArgs...], false)`. It polls each frame by reading `get_length()` bytes from stdout and stderr, then on exit drains the pipes and reads `get_process_exit_code`. **Kill:** on timeout or `notifications/cancelled` for the request, `OS.kill(-pid)` sends SIGKILL to the child's group. Afterwards `exitCode` is null, and `is_process_running` is never called again. **The child never runs the server:** it is never editor mode, so no EditorPlugin loads, and user args sit after `--`. **Limits:** no SIGTERM grace; descendants that call `setsid` (including anything Godot itself spawns) escape the group kill; Linux is verified, macOS UNCONFIRMED, Windows unsupported (D29 already refuses to start there). `build_dotnet` (slice 8): `execute_with_pipe("/usr/bin/env", ["-C", root, "DOTNET_NOLOGO=1", "DOTNET_CLI_TELEMETRY_OPTOUT=1", "MSBUILDDISABLENODEREUSE=1", "dotnet", "build", <csproj>, v0 D13 flags])`, with the v0 D14 MSBuild parser and D15 csproj rule. | A child `--import` would race the editor's own importer on `.godot/`. `env -C` gives cwd and env without mutating the editor's environment. | A child `--import`. Blocking `OS.execute`. A `GODOT_MCP_DISABLE` env var (no env parameter exists, and `OS.set_environment` would change the editor's own environment). A `--` sentinel arg (only needed for editor-mode children, which are never spawned). |
| D45 | **Output parser port** (`output_parser.gd` from `src/godot/output-parser.ts`). Prefixes `USER SCRIPT ERROR\|USER ERROR\|USER WARNING\|SCRIPT ERROR\|SCRIPT WARNING\|ERROR\|WARNING: `; `^\s+at: fn (file:line)`; the `GDScript backtrace` header and frames, where the first frame sets the location; .NET `at Ns.Type(` frames; any other line ends the diagnostic. Every diagnostic is counted but only 200 are kept. Lines are split on **bytes** (0x0A) before UTF-8 decoding, `\r` is stripped, and the last partial line is flushed at the end. Each stream keeps a 64 KB tail. `ok = exitCode == 0 && !timedOut && errorCount == 0` (v0 D5). Parsing is incremental, before tails are trimmed (D6). `frames` ≥ 1 maps to `--quit-after`; omitted means run until quit or timeout (D8). | Same rules as v0, so the same fixtures prove it | Parsing after truncation |
| D46 | **Job guard.** One job (`run_headless`, `import_assets`, `build_dotnet`) at a time per editor; the next gets `PROJECT_BUSY` immediately. `run_headless` first waits, within `timeoutSec`, for `!is_scanning()`, and reports `unsavedScenes` because a run uses files on disk. | One editor per project (the port) makes the editor the lock | v0's cross-process mkdir lock: a stale foreign pid can't be checked from GDScript, and only one server remains |
| D47 | **Fate of the TS code.** `src/*` (server, proc, lock, paths, godot/*, tools/*), `tests/unit`, `tests/godot`, `tests/stdio.test.ts` and `tests/fakes/fake-godot.sh` retire in slice 9, once parity is green. `package.json` drops `@modelcontextprotocol/server` and `zod`, and `check` becomes `biome ci . && tsc --noEmit && bun test tests/editor`. `tests/editor` with `@modelcontextprotocol/client` stays as the dev-only conformance lane. v0 slices 3–5 are never built in TS. | One product. The tests stay because they are the only external protocol check. | Keeping both servers (open question 1) |
| D48 | **Timeouts.** Responses are JSON only, so the first byte arrives at the end. The generated `.mcp.json` entry sets `"timeout": 600000`, which also lifts Claude Code's first-byte timer, and job `timeoutSec` is capped at 540. Tests pass `{timeout}` to the SDK, whose default is 60 s. | Without this, any job longer than 60 s fails in Claude Code | SSE with early headers: more state, and progress doesn't extend the wall clock |
| D49 | **`build_dotnet` is always listed.** This amends the registration part of v0 D15; the exactly-one csproj rule stays, enforced by the handler: none gives `FILE_NOT_FOUND`, several give `AMBIGUOUS_MATCH`. A csproj added or removed mid-session needs no restart. | The tool list is built once, and `listChanged` is false, so a gated list hid the tool until restart (issue 002) | Re-register on filesystem change with `list_changed` |
| D50 | **C# scripts and `create_dotnet_project` (issue 001).** `create_script` and `edit_script` take `.cs`; `validate_script` stays `.gd`-only. A new `.cs` is `using Godot;`, an optional file-scoped `namespace`, and `public partial class <file name> : <extends>`; `className` is refused for `.cs` and `namespace` for `.gd`. `extends` must be a ClassDB class: a GDScript `class_name` is not a C# base, and a C# global class would need its namespace. A `.cs` write returns `diagnostics: []` plus `note: "C# diagnostics come from build_dotnet"` and never loads the script. A `.cs` script attaches with `update_property` only after `build_dotnet`, since an unbuilt `CSharpScript` has an empty `get_instance_base_type()` (`node_props.gd`); this is confirmed by the build test. `create_dotnet_project` cannot call GodotTools' private `CreateProjectSolution`, so `dotnet_project.gd` writes the 4.7.2 templates: the csproj of `ProjectGenerator.GenGameProject`, with `Godot.NET.Sdk/<major.minor.patch>` and, for a numbered pre-release, `-<status>.<n>` as `build_assemblies.py` does (an unnumbered status such as `dev` gives `-dev`; UNCONFIRMED against a real non-stable build); and the sln of `DotNetSolution.Save` with a random v4 GUID and a BOM. Names follow `GodotSharpDirs`: `dotnet/project/assembly_name`, else the project name with `: * ? " < > \| / \\ ; ' = ,` replaced by `-`, and `dotnet/project/solution_directory` for the sln (only inside the project). `RootNamespace` uses Godot's character rules but not its keyword `@` prefix. Refuses `FILE_EXISTS` for any root csproj or an existing sln, and `DOTNET_UNAVAILABLE` when `CSharpScript` is not in ClassDB (a csproj the editor cannot build or load is no use). | An agent can set up a .NET project with no hand-written files | Calling the editor action (not exposed to GDScript); accepting GDScript classes as C# bases |

Limits (v0 D17 kept and extended):

- At most 4 peers.
- Header block: 16 KB (431).
- Body: 1 MB, checked before reading (413).
- Ingress deadline: 5 s (408).
- Write deadline: 10 s.
- Response: 4 MB.
- Nodes: 2,000, with `truncated`.
- Script reads and writes: 1 MB.
- Log ring: 1,000 entries.
- Job output tails: 64 KB per stream; diagnostics: 200.

## Repo layout

```
addons/godot_mcp/plugin.cfg  plugin.gd  setup.gd     # lifecycle, port, token, .gitignore, tool menu, skill install
addons/godot_mcp/http_server.gd  mcp_server.gd  schema.gd
addons/godot_mcp/value_codec.gd  res_paths.gd  log_buffer.gd  output_parser.gd  job_runner.gd  msbuild_parser.gd
addons/godot_mcp/tools/{project,scene,node,script,editor,job}_tools.gd
addons/godot_mcp/SKILL.md
fixtures/gd/{rich.tscn,sub.tscn,broken_ref.tscn,flood.gd,split_line.gd}  (+ existing diag.gd, quit_code.gd, hang.gd)
fixtures/cs/**                                        # slice 8, as v0 D3
tests/editor/{harness.ts,transport,conformance,read-tools,mutations,scripts,jobs,setup,build}.test.ts
tests/fakes/fake-dotnet.sh
```

## Tools

| Tool | Input | Output | Godot API | Why |
|---|---|---|---|---|
| `get_project_info` | — | `{name, godotVersion, godotPath, addonVersion, mainScene, features[], autoloads{}, dotnet: {csproj: "res://X.csproj"}\|{csproj: null, count}\|null, editedScene, openScenes[], unsavedScenes[], playingScene, scanning, jobActive}` | `ProjectSettings`, `Engine.get_version_info`, `OS.get_executable_path`, `EditorInterface.*`, `is_scanning` | First call. Covers v0 `godot_project_info` and `editor_status`. |
| `get_project_settings` | `prefix`, `limit=500` | `{settings, truncated}` | `get_property_list`/`get_setting` | Live values including defaults |
| `set_project_setting` | `name`, `value` | `{name, previous, value}` | `set_setting` + `save`; refuses `editor_plugins/enabled` and `godot_mcp/*` | Main scene, autoloads |
| `get_scene_tree` | `rootPath?`, `maxDepth=8`, `maxNodes=2000` | `{scenePath, truncated, root}` | Nodes owned by the root; instance roots not expanded | Core read |
| `open_scene` | `path` | `{editedScene}` or `SCENE_SWITCH_TIMEOUT` | `open_scene_from_path` + settle | Safe context switch |
| `create_scene` | `path`, `rootType`, `rootName?` | `{path}` | `PackedScene.pack`, `ResourceSaver.save`, `update_file`, open | New scenes |
| `save_scene` | — | `{path}` or `SAVE_FAILED` | `save_scene` + `get_unsaved_scenes` + Logger capture | Persist edits |
| `add_node` | `parentPath`, `type`\|`scene`, `name?`, `properties?` | `{path, type, undoAction}` | ClassDB checks, `GEN_EDIT_STATE_INSTANCE`, undo | Create |
| `delete_node` | `path` | `{path, undoAction}` | Owner map, index restore | Delete |
| `move_node` | `path`, `newParentPath`, `index?` | `{path, undoAction}` | Cycle/root/instance refusal, owner map | Restructure |
| `update_property` | `path`, `property`, `value` | `{previous, value, undoAction}` | Declared type, D35, `add_do/undo_property` | Update, rename, attach a script |
| `get_node_properties` | `path`, `names?` | `{properties}` | `PROPERTY_USAGE_EDITOR`, D35 | Read |
| `read_script` | `path` | `{content, unsavedInEditor}` | `FileAccess`, `get_unsaved_files` | Read code |
| `create_script` | `path` (.gd\|.cs), `extends`, `className?` (.gd), `namespace?` (.cs), `content?` | `{path, diagnostics}` (+ `note` for .cs, D50) | Write, `update_file`, validate | New code |
| `edit_script` | `path` (.gd\|.cs), `oldText`+`newText`\|`content` | `{path, diagnostics}` (+ `note` for .cs, D50) | Refuses a dirty buffer; write; `reload_open_files` | Change code |
| `validate_script` | `path` | `{ok, diagnostics}` | `reload()` + Logger around `load(CACHE_MODE_IGNORE)` | Check code (runs `@tool` static initializers, D33) |
| `get_editor_log` | `since`, `level`, `limit=200` | `{entries, nextSince, dropped}` | Persistent Logger ring | Editor errors and output |
| `play_scene` | `mode`, `path?` | `{playingScene}` | `play_*` | A human-visible run |
| `stop_scene` | — | `{stopped}` | `stop_playing_scene` | Pairs with play |
| `import_assets` | `timeoutSec=120` | `{ok, durationMs, timedOut, diagnostics, errorCount, warningCount}` | `scan()`, await `!is_scanning()`, Logger capture | Replaces `godot_import` (D44) |
| `run_headless` | `scene?`\|`script?`, `frames?≥1`, `userArgs?`, `timeoutSec=60` (≤540) | `RunResult` (v0) + `{unsavedScenes[]}` | `execute_with_pipe`, D44–D46 | Replaces `godot_run`: captured output and parsed errors |
| `install_agent_skill` | `overwrite=false` | `{skillPath, changed, mcpJson}` | `setup.gd` (D40) | Testable setup; refresh after an upgrade |
| `create_dotnet_project` | `targetFramework="net8.0"` | `{csproj, solution, assemblyName, sdk}` | `dotnet_project.gd` templates, `update_file`, D50 | Issue 001: the editor's Create C# solution is private C#, so the files are written from its templates. `FILE_EXISTS` when a root csproj or the sln exists; `DOTNET_UNAVAILABLE` without `CSharpScript` |
| `build_dotnet` *(slice 8)* | `configuration="Debug"`, `timeoutSec=300` | `{ok, exitCode, timedOut, durationMs, diagnostics, errorCount, warningCount, outputTail, truncated}` | `env -C` + `dotnet build`, D44 | Replaces v0 `godot_build`. Always listed (D49); without exactly one root csproj it fails with `FILE_NOT_FOUND` or `AMBIGUOUS_MATCH`. `get_project_info.dotnet` shows which csproj it sees. Only `Debug` refreshes what the editor and `run_headless` load. `play_scene` returns `PROJECT_BUSY` while any job runs. |

Deferred:

- screenshots (the headless editor can't render)
- runtime-game inspection and output from `play_scene` (`run_headless` captures output instead)
- input simulation
- a dedicated execute-GDScript tool (D33)
- `undo` (D34)
- duplicate, signals, groups, animation and the rest
- the 2026-07-28 era
- `--check-only` validation

## Slices

Each slice is one commit. The check is `bun run check` plus anything listed. The order is 1 → 2 → 3 → 4 → 5 → 6 → 7 → 9; slice 8 can run any time after 5, and its e2e half is blocked on .NET.

### Slice 1. Transport core (coder-max). **Critical for every later slice.**

- **Files:** `plugin.cfg`, `plugin.gd`, `http_server.gd`, `mcp_server.gd`, `schema.gd`, `tools/project_tools.gd` (`get_project_info` without job fields), `tests/editor/{harness.ts,transport.test.ts,conformance.test.ts}`
- **Depends on:** nothing. `tests/helpers.ts` is reused.
- **First step, the gate:** a throwaway plugin in a temp copy under `--headless --editor` proves A1 (markers from `_enter_tree` and `_process`), then open → one undo-managed `add_child` → `save_scene` → a changed `.tscn` on disk (A9). Record the round trip. **If this fails, stop and report.**
- **Acceptance criteria:**
  - Token and port:
    - `headers.json` is 0600, holds 64 hex, and changes on restart; no `.tmp` remains
    - `.godot/godot_mcp/.gitignore` exists
    - with the port setting missing, the plugin picks and saves one in 6550–6649
    - listens on 127.0.0.1 only (`ss -ltn` in the notes)
  - Conformance, run twice (default and `auto`): `initialize`; `notifications/initialized` gets 202 and the GET gets 405; name, instructions and `listTools`; `callTool get_project_info`; no `onerror`.
  - Negative tests:
    - bad Origin 403; no Origin succeeds; bad Host 403
    - missing token 401; wrong token 401
    - 2 MB body 413; headers over 16 KB 431; no length 411; chunked 411; `text/plain` 415
    - bad JSON -32700; an array -32600; a missing `jsonrpc` -32600
    - unknown method -32601; `server/discover` with a legacy header -32601; the `auto` probe 400
    - a notification or client response gets 202 with an empty body
    - GET and DELETE 405; `/other` 404
    - bad version 400; no version header succeeds
  - Framing and peers: a split body and dribbled headers are served; a stall gets 408 at 5 s; a fifth peer is closed.
  - A second editor on the same port leaves the token unchanged.
  - No `SCRIPT ERROR` in the editor's output.

### Slice 2. Read tools, codec, log, backpressure (coder-high)

- **Tools:** `get_project_settings`, `get_scene_tree`, `open_scene`, `get_node_properties`, `get_editor_log`. **Files:** `value_codec.gd`, `res_paths.gd`, `log_buffer.gd`, `tools/*`, `fixtures/gd/{rich,sub,broken_ref}.tscn`, `tests/editor/read-tools.test.ts`
- **Depends on:** slice 1
- **Acceptance criteria:**
  - A11 is pinned; `NO_SCENE` when no scene is open.
  - After opening, the tree matches exactly, and the instance is shown but not expanded. Open followed by an immediate read returns the new scene.
  - A 3,000-node scene gives `truncated` with exactly `maxNodes` nodes; `maxDepth` is honored.
  - Property values are exact (Vector2 literal, a texture path, native text); the `names` filter works; `NODE_NOT_FOUND`.
  - `get_project_settings` includes defaults.
  - Opening `broken_ref.tscn` logs an error; the `since` cursor works.
  - Path rejections, including an escaping symlink.
  - Backpressure: a stalled reader of the 3,000-node tree doesn't block a second client, and it is closed at the write deadline.

### Slice 3. Mutations, settings, play and stop (coder-high)

- **Tools:** `create_scene`, `save_scene`, `add_node`, `delete_node`, `move_node`, `update_property`, `set_project_setting`, `play_scene`, `stop_scene`. **Test:** `tests/editor/mutations.test.ts`
- **Depends on:** slice 2
- **Acceptance criteria.** Persistence is always checked by `save_scene` followed by reading the `.tscn` on disk.
  - Every mutation reports an `MCP:` `undoAction`.
  - An added node is saved with its properties; an instance is saved as an `ExtResource`; bad types are refused.
  - A delete with a grandchild removes both. A move into a descendant is refused. A valid move keeps the grandchildren.
  - Codec rejections: int `2.5`, a Color given for a Vector2, `"Vector2 (1, 2)"`, `"[Object (RefCounted,)]"`, `res://../x`. `name` renames and `script` attaches.
  - A read-only `.tscn` gives `SAVE_FAILED`.
  - `create_scene`: success, and refusal of an existing path.
  - `set_project_setting` lands on disk; protected keys are refused.
  - play and stop toggle `playingScene`.
  - Undo replay is covered only by the GUI smoke test. **Passed 2026-10-15:** the user ran Ctrl+Z and Ctrl+Shift+Z in a GUI editor over add, set, add, move and delete edits made through MCP.
- **Carried from slice 2 review:**
  - `value_codec.gd:60` writes a non-String Dictionary key as its `var_to_str` text, so `{1: a, "1": b}` collapses to one key. The input codec must not inherit this.
  - Writes reuse `res_paths.check_file`. Check whether an in-project `<path>.remap` can redirect a save (UNCONFIRMED).

### Slice 4. Script tools (coder-high)

- **Tools:** `read_script`, `create_script`, `edit_script`, `validate_script`. **Test:** `tests/editor/scripts.test.ts`. **First step:** A7; if no lines arrive, ship `lineUnknown: true`.
- **Depends on:** slice 3
- **Acceptance criteria:**
  - Exact read; wrong type; 2 MB gives `TOO_LARGE`.
  - Create, then attach through `update_property`; an existing path is refused.
  - `NO_MATCH` and `AMBIGUOUS_MATCH`; a syntax error on line 3 is written and reported at line 3.
  - Validation of broken and clean files.
  - The dirty-buffer refusal is checked by code review only.
- **Carried from slice 3 review** (minor; all done in slice 4 except the last):
  - `value_decoder.gd:122-124` checks finiteness as a double, so `Vector2(1e300, 0)` saves as `inf`. Bound 32-bit element types at ±3.4028235e38.
  - `play_scene`'s autosave guard may refuse when an untitled modified scene is open (`save_problem("")`). The editor skips path-less scenes, so skip them too (UNCONFIRMED whether the list holds `""`).
  - `set_project_setting` refuses `uid://` values for `main_scene` and autoloads. Resolve them with `ResourceUID` and check the resolved path (UNCONFIRMED how 4.7 stores them).
  - The test harness leaves its `/tmp/godot-mcp-*` copies behind; 526 had piled up. Clean them up in `afterAll`. Done for the editor harness only (`removeProjects`). The v0 `tests/godot/*` and unit tests (`lock-`, `proc-` directories) still leak; they retire with the TS server in slice 9, so they are left alone.
  - For slice 8: an unbuilt C# script's `get_instance_base_type()` is likely `""`, so attaching it is refused. **Checked in slice 8 (4.7.2.mono, headless editor):** confirmed. `update_property` on `Main.cs` before any build gives `INVALID_VALUE` ("extends nothing valid"). The attach succeeds about 1 s after an out-of-process `build_dotnet` finishes, because the editor picks up the new assembly by itself (polled at 1 s steps; not at 0 s). No code fix; SKILL.md tells the agent to retry. GUI editor UNCONFIRMED.
  - **Dropped on purpose (slice 8):** v0's e2e "a broken build stops the run" has no v1 counterpart, because `run_headless` has no build phase; the agent calls `build_dotnet` first.
  - **Parser limits (slice 8):** only the first line of a multi-line MSBuild message is kept (continuation lines have no prefix; they stay in `outputTail`); a missing `dotnet` surfaces as exit 127 with a `BUILD_FAILED` diagnostic that names it, not as `SPAWN_FAILED`, because the spawn of `env` succeeded. `--disable-build-servers` leaves no MSBuild, VBCSCompiler or Razor survivors after a real SDK 10.0.112 build, same as the current flags (which also work on older SDKs), so the flags stay.
  - **Cold restore needs network (slice 8):** a first `dotnet build` of `fixtures/cs` fetches `Godot.NET.Sdk`, `GodotSharp`, `Godot.SourceGenerators` and the net8.0 reference pack from nuget.org (a cold cache restored in about 3 s). With them in `~/.nuget/packages` the build runs offline (verified with a dead proxy).

### Slice 5. Headless jobs and parser port (coder-high). **Parity gate.**

- **Files:** `job_runner.gd`, `output_parser.gd`, `tools/job_tools.gd`, `fixtures/gd/{flood.gd,split_line.gd}`, `tests/editor/jobs.test.ts`
- **Tools:** `import_assets`, `run_headless`. Also adds `jobActive` to `get_project_info`.
- **Depends on:** slice 4
- **Carried from slice 4 review** (minor): Godot buffers small writes until `fclose`, and `FileAccessUnix::_close()` ignores that result before renaming. A full disk during a small `edit_script` can therefore leave an empty file while the tool reports success. After `close()`, read the file back and compare it with the written bytes; on a mismatch, take the restore or remove path.
- **First step:** pin A12 and A13 with `hang.gd` (`OS.kill(-pid)` leaves the pid dead, and later calls don't log ECHILD noise) and with partial pipe reads. **If non-blocking reads or the kill fail, stop and report.**
- **Acceptance criteria** (v0 slice 2, ported):
  - `diag.gd` gives exactly the kinds, messages and locations the current `tests/godot/run.test.ts` expects.
  - `quit_code.gd` gives exit 3 and `ok: false`. `frames: 30` on the main scene is `ok`.
  - `hang.gd` with `timeoutSec: 2` gives `timedOut`, and the child is dead.
  - An early `ERROR` followed by more than 200 KB of stdout (`flood.gd`) gives `ok: false`, `errorCount ≥ 1` and `truncated`.
  - `split_line.gd` writes `ERR`, sleeps 300 ms, then writes `OR: x\n` through `/dev/stderr`. It parses as one error. A multibyte character split across chunks is intact.
  - A second concurrent job gets `PROJECT_BUSY`.
  - Cancelling through an SDK `AbortSignal` kills the child.
  - Other tools answer during a 5 s run.
  - `unsavedScenes` is reported.
  - Scene and script path validation; `userArgs` come after `--`.
  - `import_assets`: a new PNG copied into the temp project yields its `.godot/imported/*.ctex` (A14). A15 is recorded in the notes.

### Slice 6. Self-setup and skill install (coder)

- **Files:** `setup.gd`, menu wiring in `plugin.gd`, `install_agent_skill` in `tools/project_tools.gd`, `tests/editor/setup.test.ts`
- **Depends on:** slice 1 (and slice 5, so the generated `.mcp.json` entry carries `timeout`)
- **Acceptance criteria:**
  - `install_agent_skill` writes `<tmp>/.claude/skills/godot-mcp/SKILL.md` byte-equal to the addon copy. A second call gives `changed: false`.
  - A symlinked `.claude` or `skills` directory is refused. A foreign SKILL.md is refused without `overwrite` and replaced with it.
  - No other file changes (a tree diff of the temp project).
  - `mcpJson` has the url, the port, `timeout: 600000`, and a `headersHelper` path quoted correctly for a project path containing a space and a `'`. Running that helper string through `sh` prints valid headers.
  - The menu item is added and removed with the plugin. Clicking it is checked in the GUI smoke test.

### Slice 7. SKILL.md and instructions (scribe; load `authoring:create-skill`)

- **Files:** `addons/godot_mcp/SKILL.md`, the instructions constant, a drift check in `conformance.test.ts`
- **Depends on:** slice 6
- **Content:**
  - one server; call `get_project_info` first
  - the edit loop: open → tree → mutate → `save_scene` → `run_headless`
  - `import_assets` after adding assets
  - value syntax, errors and limits
  - jobs and `PROJECT_BUSY`
  - `play_scene` doesn't capture output
  - code execution (D33)
  - latency when the editor is unfocused
  - troubleshooting: connection refused (editor closed, plugin disabled, wrong port), 401 (trust dialog, restart, reconnect), `MCP_PROTOCOL_NEGOTIATION=legacy`, timeouts
  - running a headless editor as a service
- **Acceptance criteria:**
  - Create-skill checks pass, and the frontmatter carries the marker D40 uses.
  - Every `tools/list` name appears in SKILL.md. The instructions are at most 2,000 characters.
  - The editor loads with no error about the `.md` file (A16).

### Slice 8. `build_dotnet` (coder-high)

- **Files:** `msbuild_parser.gd`, `build_dotnet` in `tools/job_tools.gd`, `fixtures/cs/**` (v0 D3), `tests/fakes/fake-dotnet.sh`, `tests/editor/build.test.ts`
- **Depends on:** slice 5
- **Acceptance criteria, run now with fake-dotnet on `PATH` through the harness:**
  - The v0 slice 3 parser cases: located CS errors and warnings, `x.csproj : error NU1301`, `MSBUILD : error MSB1009`, diagnostics without a code, de-duplication, `BUILD_FAILED`.
  - Zero csprojs or more than one is an error.
  - `cwd` is the project root (asserted by the fake).
  - A `sleep` the fake starts in the background is dead after a timeout, which proves the group kill reaches same-group grandchildren.
- **Acceptance criteria, e2e:** the v0 slice 3 e2e list, run through the addon.

### Slice 9. Retire the Bun server (coder)

- **Depends on:** slices 5 and 7 green, and the operator using the addon in `lagrange-protocol`.
- **Change:** delete what D47 lists, update `package.json`, rewrite the README for the addon (install, setup menu, `.mcp.json`, dev conformance lane).
- **Acceptance criteria:** `bun run check` (now `tests/editor` only) passes; `rg "@modelcontextprotocol/server|src/"` finds nothing outside git history.

## Risks and rollback

| Risk | Mitigation |
|---|---|
| A1 or the headless open→edit→save path fails | The slice 1 gate stops work; the user decides |
| No tools work without an open editor, including run and import | Run a headless editor as a service (SKILL.md, README); open question 2 |
| `OS.kill(-pid)` behaves differently at runtime (A12) | The slice 5 gate. The fallback is `OS.kill(pid)`, with the grandchild gap documented. |
| No graceful kill; descendants that call `setsid` survive | Documented. Headless game runs rarely spawn processes. Build sets `MSBUILDDISABLENODEREUSE`. |
| A job runs on stale state (unsaved scenes, an in-progress import) | Waits for `!is_scanning()`; reports `unsavedScenes`; SKILL.md says to save first |
| A headless child and the editor both touch `.godot/` (A15) | Notes from slice 5. A child `--import` is never spawned. |
| First-byte timeout on long jobs | `timeout: 600000` in the entry; 540 s cap (D48) |
| Bugs in the GDScript HTTP parser | Small subset, `Connection: close`, the negative suite |
| The editor thread blocks | Non-blocking writes, FIFO, re-entrancy guard, jobs outside the FIFO |
| Latency when the editor is unfocused | Measured; documented |
| Claude Code's classifier differs from SDK 2.3.1 (A10) | Operator check; `MCP_PROTOCOL_NEGOTIATION=legacy` |
| `headersHelper` waits for the trust dialog | Operator step; SKILL.md |
| Platforms: Windows lacks chmod and `kill(-pid)`; macOS lacks a verified `env -C` | Server refuses to start on Windows; Linux is supported; macOS UNCONFIRMED |
| Same-user processes can read the token | Accepted |
| Code runs in the editor process or a child | The token is the boundary (D33) |
| Errors raised before the plugin loads are missing from the log | Documented |
| The legacy era is deprecated later | 12-month or longer window; add a modern slice then |
| Rollback | Each slice is one commit, so `git revert`. Before slice 9 lands, the Bun server still works. Consumer touchpoints: the addon folder, one `project.godot` key, `.claude/skills/godot-mcp/`, one `.mcp.json` entry. |

## Critique log

| # | Point (codex, round 1) | Status |
|---|---|---|
| 1 | Blocking `put_data` and unbounded response bytes | adopted (D27, limits, slice 2 backpressure test) |
| 2 | The `str_to_var` blacklist can be bypassed | adopted, verified at `variant_parser.cpp:995-1170` (D35) |
| 3 | No execution boundary; `CACHE_MODE_IGNORE` reuses dependencies | adopted (D33, `validate_script` notes) |
| 4 | Undo loses descendant owners; test undo replay | partly adopted: owner maps and owned-only structural edits. rejected: an undo-replay test, since no bound `undo()` exists; the GUI smoke test covers it. |
| 5 | A plain dispatch flag doesn't settle async scene switches | adopted (D37) |
| 6 | `save_scene()` returns OK on failure | adopted, verified at `editor_interface.cpp:763-773` |
| 7 | Token publishing races; unquoted helper path | adopted (D29, slice 6 quoting test) |
| 8 | Import and editor coexistence | adopted further in revision 2: no child `--import` at all; import runs in the editor (D44, D46) |
| 9 | Weak gate; defer settings | partly adopted (open→edit→save gate). rejected: deferring `set_project_setting`, which the user listed |
| 10 | The `auto` probe gets 400; GET after init; no DELETE | adopted (D25, D28) |

Revision 2 (the user's decisions: one addon server, self-setup, no GDExtension) made no new second-opinion call. The new headless-run design was checked against 4.7.2 source instead: `os_unix.cpp` (setsid, kill, exit codes), `file_access_unix_pipe.cpp` (non-blocking reads, FIONREAD), `core_bind.cpp` (`OS.kill(int)`).

second opinion: codex gpt-6-astra/xhigh — adversarial plan critique, round 1; timed out (exit 124)
second opinion: codex gpt-6-astra/high — adversarial plan critique, round 1 retry; 10 findings

## Open questions (resolved with the recommended defaults; user may override)

1. **TS code:** retire the Bun server after parity (slice 9) and keep `tests/editor` as a dev-only lane (D47).
2. **No editor, no tools:** accepted; run a headless editor as a service for CI (D31).
3. **Import:** an in-editor `EditorFileSystem.scan()`, not a child `--import`, to avoid two importers racing (D44).
4. **`install_agent_skill`:** exposed as a tool as well as the menu item (D40).
5. **Kill:** group SIGKILL through `OS.kill(-pid)` with no grace period (D44).
6. **Timeouts:** `.mcp.json` `timeout: 600000`; jobs capped at 540 s (D48).
7. **Port:** auto-picked once in 6550–6649, then fixed (D30).
8. **Tool surface:** 22 tools plus `build_dotnet` and `create_dotnet_project`; no `undo` (D32, D34).
9. **Era:** legacy only; dual-era later (D25).
10. **Execute GDScript:** no dedicated tool; the script writers run code (D33, user decision in slice 4).
11. **Distribution:** copy or Asset Library; publishing to the Asset Library is a later step.
12. **GDExtension:** no; stays GDScript (D43).

## Not verified

- A1, A9–A16, and the editor's low-processor sleep defaults.
- Whether `Node.reparent` preserves descendant owners (made irrelevant by the owner map).
- `headersHelper` behavior when `headers.json` is missing.
- macOS overall (chmod is documented; `env -C` and `kill(-pid)` are not checked).
- Whether tool-menu items exist under `--headless`. The tool path gives the coverage.
