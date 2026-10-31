---
name: godot-mcp
description: Drives the Godot editor open on a project through its godot-editor MCP server, from the godot_mcp addon. Use it in a Godot project with the addon enabled for tasks such as "add a Sprite2D under Player", "set the collision size", "write a script and attach it", "run the main scene headless", or "the MCP server won't connect". Not for Godot projects without the addon.
metadata:
  godot_mcp: "true"
---

# Godot MCP

The `godot-editor` server is the open Godot editor, serving one project. Its tools read and change the editor's live state. The editor must be running with the godot_mcp plugin enabled. With no editor, no tools respond.

## Start

1. Call `get_project_info`. It returns the project name, main scene, features, autoloads, `plugins` (each `{name, enabled, version}`), `dotnet`, open and unsaved scenes, the playing scene, and `jobActive`. `dotnet` is `{csproj: "res://X.csproj"}` for one root csproj, `{csproj: null, count: N}` for several, and `null` for none. `build_dotnet` works only in the first case.
2. If `jobActive` is true, wait before you call `run_headless`, `import_assets`, or `build_dotnet`. Otherwise the call fails with `PROJECT_BUSY`.

## Know where a change lives

- Node edits (`add_node`, `delete_node`, `move_node`, `update_property`) change the edited scene in the editor. Each is one undo step. None of them reaches disk until `save_scene` succeeds.
- `create_scene` writes its new `.tscn` at once. `open_scene` only switches scenes.
- Script writes (`create_script`, `edit_script`), `set_project_setting`, `add_input_action`, `enable_plugin` and `disable_plugin` write files at once.
- `run_headless` and `read_script` read files on disk. Save first, or the run uses the old content. `run_headless` lists the scenes still unsaved in `unsavedScenes`.

## Edit a scene

1. Open the scene with `open_scene`, or make one with `create_scene`. Node tools need an edited scene and fail with `NO_SCENE` without one.
2. Read the node paths with `get_scene_tree`. Paths are relative to the scene root, and `"."` is the root.
3. Change the scene with `add_node`, `update_property`, `move_node`, or `delete_node`.
4. Call `save_scene`. Check that it returns no error.
5. Call `run_headless` with `scene` set to the edited scene's `res://` path. Read `ok` and the parsed `diagnostics`. Godot exits 0 after a script error, so the exit code alone proves nothing. The run reads files on disk, so step 4 must have succeeded.

## Write a script

1. Call `create_script` with `path`, `extends`, and optionally `className` and `content`. The response holds the script's diagnostics. A syntax error still writes the file, so read the diagnostics.
2. For `@tool` or another leading annotation, create the file, then replace it with `edit_script` and `content`. The body that `create_script` writes comes after the `extends` line.
3. Attach it with `update_property`, using `property: "script"` and `value` set to the script's `res://` path. Then call `save_scene`.
4. After a later change, `edit_script` returns diagnostics too. Call `validate_script` to recheck a file alone.

For C#, give `create_script` a `.cs` path. The file name must be an identifier, because it names the class. The tool writes `using Godot;`, an optional file-scoped `namespace` (`namespace: "Game.Actors"`), and `public partial class <file name> : <extends>`, with `content` as the class body. Give `content` unindented, since each non-empty line gets four spaces, including lines inside multi-line string literals. For `.cs`, give `extends` in its C# spelling, which the engine renames for some classes (`GodotObject`, `GpuParticles2D`, `HttpRequest`). It is written as given, and `build_dotnet` reports a wrong name. `className` is refused for `.cs`, and `namespace` for `.gd`. A `.cs` write returns `diagnostics: []` and a `note`, because only `build_dotnet` finds C# errors. `validate_script` is `.gd` only.

## Add an input action

`add_input_action` writes `input/<name>` to `project.godot`, as the editor's Input Map tab does. A game started by `run_headless` or `play_scene` reads it at start, so no restart is needed. The editor's own input map is not changed, so editor shortcuts stay as they were.

- An event is a string in Godot's key syntax, which means a physical key: `"Ctrl+P"`, `"F1"`, `"Alt+1"`. Or an object: `{type: "key", key: "P", modifiers: ["Ctrl"], physical: true}`, `{type: "mouseButton", button: "right", modifiers: ["Shift"]}`, `{type: "joypadButton", button: 0}`. `physical: false` binds the key by its layout character instead of its position. `device` defaults to -1, every device.
- Modifiers are `Ctrl`, `Shift`, `Alt`, `Meta` and `CmdOrCtrl` (Ctrl, or Command on macOS), any case, each at most once. An unknown modifier, key name or button is `INVALID_VALUE` naming `events[i]`. At most 32 events.
- The events replace the action's old ones, and a new action gets deadzone 0.2. An existing action keeps its deadzone unless you give one. With `append: true` only events the action lacks are added, so a repeat changes nothing. `events: []` empties an action. Removing one is not supported.
- The result holds `events` and `previous` (`null` for a new action) in the same shape. An event that shape can't express comes back as `{type: "other", text}`. `editorRefreshed` is whether the open Project Settings dialog was told to reload its Input Map tab.
- Existing events are only reported as `previous` when you replace them; `get_project_settings` shows an event as `{class, type: "Object", value: null}`. `set_project_setting` refuses `input/`.

## Add assets

After you add or change images, models, or audio, call `import_assets` before `run_headless` or `play_scene`. It rescans the project and returns `errorCount`, `warningCount`, and `diagnostics` for the import.

## Build C#

`build_dotnet` builds the one `.csproj` in the project root, as a Godot .NET project has. With none it fails with `FILE_NOT_FOUND`, and with several it fails with `AMBIGUOUS_MATCH`. Adding or removing a `.csproj` takes effect on the next call, with no restart.

In a project with no `.csproj`, call `create_dotnet_project` first. It writes the root `.csproj` and the `.sln` the way the editor's Create C# solution does, and returns their `res://` paths. The names come from `dotnet/project/assembly_name` (else the project name), and the `.sln` goes in `dotnet/project/solution_directory`. `targetFramework` defaults to `net8.0`. It fails with `FILE_EXISTS` when the root holds a `.csproj` or the `.sln` exists, and with `DOTNET_UNAVAILABLE` in an editor without .NET support.

1. Edit the `.cs` files, or make them with `create_script`.
2. Call `build_dotnet`. Read `ok` and `diagnostics`. Each has `code` (such as `CS1002`), `file` (a `res://` path when the file is in the project), `line`, `column`, and `message`.
3. Fix the errors and build again. Run the project with `run_headless` once the build is `ok`.

- Build with the default `Debug` configuration. The editor and `run_headless` load only `.godot/mono/temp/bin/Debug`, so another `configuration` only checks that the code compiles.
- A failure that prints no error becomes a `BUILD_FAILED` diagnostic. Read `outputTail` for the cause. A missing `dotnet` gives `exitCode` 127 and a message that says so.
- Only the first line of a multi-line MSBuild message is in `diagnostics`; the rest is in `outputTail`. `truncated` is true when `outputTail` was cut to its last 64 KB.
- The first build restores NuGet packages and needs network access unless they are already cached.
- A C# script can be attached with `update_property` only after a build (a new or changed script needs one), and the editor needs about a second after `build_dotnet` returns to load it. Until then, `update_property` fails with `INVALID_VALUE`. Retry.
- The build runs the project's MSBuild targets, analyzers, and source generators. See Code runs in the editor.

## Tools

| Tool | Does | Arguments |
| --- | --- | --- |
| `get_project_info` | Read the project, editor, and job state. Call first. | none |
| `get_project_settings` | Read settings with their defaults, sorted by name. | `prefix`, `limit` (default 500, max 5000) |
| `set_project_setting` | Write a setting to `project.godot`. Refuses `editor/`, `editor_plugins/` (use `enable_plugin` and `disable_plugin`), `input/` (use `add_input_action`), and `godot_mcp/`. | `name`, `value` |
| `add_input_action` | Write an input action with key, mouse, and joypad events to `project.godot`. Replaces the action's events unless `append` is true. | `name`, `events` (at most 32), `deadzone` (0 to 1), `append` |
| `install_agent_skill` | Write this skill into the project and return the `.mcp.json` entry. | `overwrite` |
| `get_scene_tree` | List the edited scene's nodes, breadth first. | `rootPath`, `maxDepth` (default 8, max 64), `maxNodes` (default 2000, max 10000) |
| `open_scene` | Make a `.tscn` or `.scn` the edited scene. | `path` |
| `create_scene` | Make a new `.tscn` with a root of class `rootType`, and open it. | `path`, `rootType`, `rootName` |
| `save_scene` | Write the edited scene to its file. | none |
| `add_node` | Add a node of class `type`, or an instance of `scene`. | `parentPath`, `type` or `scene`, `name`, `properties` |
| `delete_node` | Delete a node and its children. The root can't be deleted. | `path` |
| `move_node` | Move a node under a new parent, or reorder it. The root can't move. | `path`, `newParentPath`, `index` |
| `get_node_properties` | Read a node's editor-visible properties. | `path`, `names` |
| `update_property` | Set one property. `script` attaches a script, and `name` renames the node. | `path`, `property`, `value` |
| `read_script` | Read a `.gd` or `.cs` file as text. | `path` |
| `create_script` | Create a `.gd` or `.cs` file. A `.gd` file returns its diagnostics; a `.cs` file returns none (see `build_dotnet`). | `path`, `extends`, `className` (`.gd`), `namespace` (`.cs`), `content` |
| `edit_script` | Replace one exact `oldText` with `newText`, or the whole file with `content`, in a `.gd` or `.cs` file. | `path`, and `oldText` and `newText` or `content` |
| `validate_script` | Reload a `.gd` file from disk and report its first parse error. | `path` |
| `run_headless` | Run the project, a scene, or a script in a separate headless process. | `scene` or `script`, `frames`, `userArgs`, `timeoutSec` (default 60, max 540) |
| `import_assets` | Rescan the project and import new or changed assets. | `timeoutSec` (default 120, max 540) |
| `create_dotnet_project` | Write the root `.csproj` and the `.sln`, as Create C# solution does. Refuses an existing one. | `targetFramework` (default `net8.0`) |
| `build_dotnet` | Build the root `.csproj` with `dotnet build`. Needs exactly one in the root. | `configuration` (default `Debug`; only Debug refreshes what the editor and `run_headless` use), `timeoutSec` (default 300, max 540) |
| `get_editor_log` | Read the editor's errors, warnings, and printed output. | `since`, `level`, `limit` (default 200, max 1000) |
| `play_scene` | Run a scene in the editor's play mode. Output is not captured. | `mode` (`main`, `current`, or `custom`), `path` for `custom` |
| `stop_scene` | Stop the scene that is playing. | none |
| `enable_plugin` | Enable the plugin in `res://addons/<name>/` in the open editor, and write `project.godot`. Returns `changed: false` if it was already enabled. A C# plugin needs `build_dotnet` first. | `name` (the folder under `addons/`, such as `marker` or `vendor/foo`; `get_project_info` lists them) |
| `disable_plugin` | Disable that plugin and write `project.godot`. Returns `changed: false` if it was already disabled. Refuses `godot_mcp`. | `name` |
| `capture_viewport` | Take a PNG of the running game's window and return it as an image. | `path` (a new `res://` `.png`), `inline` (default true), `timeoutSec` (default 10, 1 to 60) |

## Values

`value` and `properties` are parsed by the property's declared type.

| Declared type | Send | Example |
| --- | --- | --- |
| `bool`, `int`, `float`, `String`, `StringName`, `NodePath` | JSON. An `int` must be a whole number. | `true`, `3`, `"Player"` |
| Math types (`Vector2`, `Rect2`, `Transform2D`, ...) and packed numeric arrays | A Godot literal string | `"Vector2(1, 2)"`, `"PackedInt32Array(1, 2)"` |
| `Color` | A literal string, or `#rrggbb` or `#rrggbbaa` | `"Color(1, 0, 0, 1)"`, `"#ff8800"` |
| `Array`, `Dictionary` | JSON. A typed array or dictionary is refused. | `[1, "a"]` |
| Resource (`Object`) | The `res://` path of a resource, or `null` | `"res://player_frames.tres"` |

- A resource path must already be in the editor's file index. Otherwise you get `INVALID_VALUE`. Wait for the scan, or call `import_assets`.
- Other types are refused with `UNSUPPORTED_TYPE`.
- A literal string is at most 4,096 characters.
- Reads come back as `{type, value}`. A resource comes back as its path and `class`, and a math value as its Godot literal.

## Errors

A tool failure returns `isError: true`, with `structuredContent.error` holding `code` and `message`. The message names the file, path, or property involved. Protocol errors come back as JSON-RPC errors instead: `-32602` for bad arguments or an unknown tool, and `-32603` for an internal error, an overrun of the 30-second budget, or a response over 4 MB.

| Code | Meaning and fix |
| --- | --- |
| `PROJECT_BUSY` | A `run_headless`, `import_assets`, or `build_dotnet` job is running. `play_scene` also gets it while a job runs, because playing starts the editor's own build. Retry when `jobActive` is false. |
| `IMPORT_IN_PROGRESS` | The editor was still importing when the run's deadline passed. Retry, or call `import_assets` first. |
| `CANCELLED` | The request was cancelled. A cancelled run is killed. A cancelled import keeps running in the editor. |
| `NO_SCENE` | Call `open_scene` or `create_scene`. |
| `NODE_NOT_FOUND`, `PROPERTY_NOT_FOUND` | Check the path with `get_scene_tree`, or the property name with `get_node_properties`. |
| `INVALID_VALUE`, `UNSUPPORTED_TYPE` | The value doesn't fit the declared type. See Values. For `add_input_action`, an event is malformed or names an unknown key, modifier, or button; the message names `events[i]`. |
| `INVALID_ARGUMENT` | The arguments conflict, for example `scene` with `script`, or `path` with a `play_scene` mode other than `custom`. A `build_dotnet` `configuration` must be letters, digits, `_`, `.`, and `-`, at most 64, and not start with `-`. |
| `DOTNET_UNAVAILABLE` | `create_dotnet_project` ran in an editor build without .NET support. |
| `INVALID_OPERATION`, `INVALID_MOVE` | The root can't be deleted or moved, or a node can't move into its own subtree. |
| `DUPLICATE_NAME` | A sibling already has that name. |
| `INVALID_NAME` | A setting name must be letters, digits, and `_` segments joined by `/`. An action name must be 1 to 128 characters, without `/`, `:`, `"`, `=`, `\`, or control characters, and without a space at either end. |
| `INVALID_TYPE` | `add_node` got a class that is unknown, abstract, editor-only, or not a Node. |
| `SCENE_CYCLE` | `add_node` with `scene` would nest the edited scene inside itself. |
| `INVALID_PATH` | A `res://` path failed a rule. It must start with `res://`, and it must be normalized, with no `..`, `\`, `:`, or control characters. It must not be under `res://.godot/`, pass through a symbolic link, or have a `.remap` file. |
| `FILE_NOT_FOUND`, `FILE_EXISTS`, `DIR_NOT_FOUND` | The file is missing, the new file already exists, or its folder is missing. `build_dotnet` returns `FILE_NOT_FOUND` when the `.csproj` has been removed since the editor started. |
| `PROTECTED_PATH`, `PROTECTED_SETTING` | Scripts under `addons/godot_mcp/` can't be written or validated, `capture_viewport` can't write there, and `enable_plugin` and `disable_plugin` refuse `godot_mcp`. The `editor/`, `editor_plugins/`, `input/`, and `godot_mcp/` settings can't be set; use `enable_plugin` and `disable_plugin` for plugins and `add_input_action` for actions. |
| `PLUGIN_FAILED` | The editor did not enable or disable the plugin, or its `plugin.cfg` can't be parsed or has no `script`. The message carries the errors the editor logged, such as a parse error in the plugin's script. A C# plugin script needs `build_dotnet` first. |
| `NO_MATCH`, `AMBIGUOUS_MATCH` | `oldText` is absent, or occurs more than once. Add surrounding text so it matches once. `build_dotnet` returns `AMBIGUOUS_MATCH` when a second `.csproj` has appeared in the project root. |
| `TOO_LARGE` | `oldText` is over 64 KB, or a script is over 1 MB. |
| `UNSAVED_EDITOR_BUFFER` | The script editor holds unsaved changes to the file. Save or revert them in the editor. |
| `SAVE_FAILED`, `WRITE_FAILED`, `READ_FAILED`, `LOAD_FAILED` | A disk or load problem. Read the message, and check `get_editor_log`. |
| `NO_GAME` | `capture_viewport` found no running game. Start one with `play_scene`. |
| `CAPTURE_TIMEOUT` | The game didn't answer within `timeoutSec`. It has no renderer when run with `--headless`, or it is paused at a breakpoint. |
| `CAPTURE_FAILED` | The game's screenshot file failed a check (see Capture the running game), or isn't a readable PNG. |
| `UNSAFE_AUTOSAVE` | `play_scene` would auto-save a scene that can't be saved safely. Fix that scene's save problem first. |
| `PLAY_FAILED`, `STOP_FAILED`, `SCENE_SWITCH_TIMEOUT` | The editor didn't start, stop, or switch within 10 seconds. Check `get_editor_log`. |
| `SPAWN_FAILED` | `run_headless` or `build_dotnet` couldn't start its process. The message names the cause: GNU `timeout` is not on `PATH`, or the editor's binary couldn't be started. A missing `dotnet` is not this code. It comes back as a `build_dotnet` result with `exitCode` 127 and a `BUILD_FAILED` diagnostic. |
| `INTERNAL` | A handler hit a script error. Check `get_editor_log`. |

The setup codes (`NOT_LISTENING`, `UNSUPPORTED_PLATFORM`, `FOREIGN_SKILL`, `MISSING_SKILL`, `IS_LINK`, `UNSAFE_PATH`) appear only in `install_agent_skill`. See Setup.

## Limits

| Item | Limit |
| --- | --- |
| Request body | 1 MB. Headers 16 KB. |
| Concurrency | One request runs at a time, in arrival order. Four connections at once; a fifth is closed. |
| Execution | 30 seconds from queueing to answer. `run_headless`, `import_assets` and `capture_viewport` set their own budget. |
| Response | 4 MB. |
| Scripts | 1 MB per read or write. `oldText` up to 64 KB. |
| Literal values | 4,096 characters. |
| `userArgs` | 64 entries, 1,024 characters each. |
| Scene tree | `maxDepth` up to 64. `maxNodes` up to 10,000. |
| Settings | `limit` up to 5,000. |
| Editor log | 1,000 entries kept. `limit` up to 1,000. |
| Diagnostics | 200 entries, 1,000 characters per line, 120,000 characters in all. |
| Scene switch, play, and stop | 10 seconds each. |
| Captures | `timeoutSec` 1 to 60, default 10. The game's file up to 64 MB and 64 megapixels. Inline images up to 1568 px on the long side. The newest 20 kept in the captures folder. |
| Job timeouts | `run_headless` defaults to 60 seconds, `import_assets` to 120, `build_dotnet` to 300, and all cap at 540. |

## Jobs

- `run_headless`, `import_assets`, and `build_dotnet` are jobs. Only one job runs at a time, and a second one gets `PROJECT_BUSY` at once.
- `run_headless` waits for a running import first. It uses its own `timeoutSec`. When the time runs out, Godot's process group is killed, and the result has `timedOut: true` and `exitCode: null`.
- `run_headless` returns `stdoutTail` and `stderrTail`, which are the ends of each stream. `truncated` is true when output was cut.
- A game killed by signal N reports `exitCode` N, the same as `exit(N)`, so the exit code alone can't tell them apart.
- A game that reads stdin waits for the timeout, because its stdin never closes.
- `import_assets` holds the request queue, so other editor tools wait behind it and fail after 30 seconds. `run_headless` lets them run meanwhile, except `play_scene`.
- `build_dotnet` returns `outputTail`, the end of the raw build output, with stderr last. On a timeout its process group is killed, and the result has `timedOut: true` and `exitCode: null`. Like `run_headless`, it lets other tools run meanwhile, except `play_scene`.
- A cancelled request stops waiting. Cancelling a `run_headless` or `build_dotnet` kills its child process.

## Run and play

- Use `run_headless` to check behavior and read output. It accepts a `scene`, a `script` that extends `SceneTree`, or nothing for the main scene. `userArgs` go to the game after `--`.
- Use `play_scene` to show a scene in the editor, like F5 to F7 in the editor. It returns once the game has started. It does not capture output. It saves every modified scene first.
- Use `stop_scene` to end a scene that `play_scene` started, or one a person started. `stopped` is false when nothing was playing.

## Capture the running game

`capture_viewport` asks the running game for a screenshot of its window, through the editor's debugger. It works for any debug run this editor started: `play_scene`, F5, or the embedded Game view. It does not capture `run_headless` runs or the editor itself.

- The PNG goes to `res://.godot/godot_mcp/captures/capture-<unix ms>.png`, which is gitignored and never imported. The newest 20 are kept. Give `path` to write a new `res://` `.png` instead; the editor imports it.
- The result is `{path, absolutePath, width, height, bytes}`, followed by an image block scaled to at most 1568 px on the long side. The image is PNG, or JPEG when the PNG would be over 2 MB. Pass `inline: false` to get only the file.
- With nothing playing the call fails at once with `NO_GAME`. Right after `play_scene` it waits for the game's debugger to connect.
- A game run with `--headless` has no renderer and can't answer, so the call ends with `CAPTURE_TIMEOUT`. Check `editor/run/main_run_args`. A game paused at a breakpoint doesn't answer either.
- The game writes the PNG into the editor's temp folder and sends its path. A path that isn't a `scr-<digits>.png` file directly in that folder, is a link, or isn't a PNG gives `CAPTURE_FAILED`, as does a frame over 64 megapixels. A game on another machine or in a sandbox always gets `CAPTURE_FAILED`.
- A reply that arrives after `CAPTURE_TIMEOUT` or `CANCELLED` is dropped, and the game's `scr-*.png` stays in the temp folder.

## Code runs in the editor

Several tools also run project code. `validate_script` and the script writers run the static initializers of `@tool` scripts. A `@tool` script with a `_static_init` runs arbitrary code in the editor. `open_scene` runs the `@tool` scripts in the scenes it loads. `enable_plugin` runs the plugin's `_enter_tree` and `_enable_plugin`, and `disable_plugin` runs its `_disable_plugin` and `_exit_tree`. `get_node_properties` can run script getters. Setting a property can run a setter. `set_project_setting` changes autoloads and the main scene, which run when the game starts. `add_input_action` runs no project code. `run_headless` and `play_scene` run the game. `capture_viewport` runs no project code beyond the game already running. `build_dotnet` runs the project's MSBuild targets, analyzers, and source generators.

There is no sandbox. The bearer token is the only boundary. `addons/godot_mcp/` refuses script writes and validation with `PROTECTED_PATH`. That guards against accidents, not against a hostile caller. Use this server only with projects you trust.

## Latency when the editor is unfocused

Calls can be slow while the editor window is in the background. The server answers from the editor's frame loop, and the editor may slow that loop in low-processor mode when its window is unfocused. The cause is not confirmed. If calls stall, bring the editor window to the front and retry.

## Troubleshoot

| Symptom | Cause | Fix |
| --- | --- | --- |
| Connection refused | The editor is closed, the plugin is disabled, or the port is wrong. | Open the project, and enable the plugin in Project Settings > Plugins. The editor prints `godot_mcp: serving http://127.0.0.1:<port>/mcp` when the server starts. Make the `.mcp.json` URL match that port. |
| `cannot listen` in editor output | The saved port is taken, or a second editor has this project open. | Close the other editor. To pick a new port, remove `godot_mcp/server/port` from `project.godot` (`set_project_setting` refuses this key), reload the plugin, then re-run setup to update `.mcp.json`. |
| 401 Unauthorized | The token changed. The plugin makes a new token each time it loads, so a restart or plugin reload invalidates the old one. | Reconnect the MCP client. The `.mcp.json` `headersHelper` reads the current token at connect time. Don't copy the token into a file by hand. |
| Claude Code doesn't connect to `godot-editor` | The project's MCP server hasn't been approved. | Accept the trust prompt for project MCP servers, then reconnect. |
| Protocol error at connect | The client negotiates the protocol differently. This server accepts `2025-11-25`, `2025-06-18`, and `2025-03-26`. | Set `MCP_PROTOCOL_NEGOTIATION=legacy` in the client's environment, then reconnect. |
| Requests time out | The `.mcp.json` `timeout` is shorter than the work. The install sets it to 600000 ms. The server gives a request 30 seconds, counting queue time. | Raise the client `timeout`. Move long work into `run_headless` or `import_assets`, and set `timeoutSec`. |
| `INVALID_VALUE`, not in the file index | The resource was added after the editor's last scan. | Call `import_assets`, or wait for scanning to finish. |
| `PROJECT_BUSY` for a long time | A job is still running. | Check `jobActive`, and cancel the request that started the job if it is stuck. |

## Run the editor as a service

For CI or an agent without a window, run the editor headless against the project:

```sh
godot --headless --editor --path <project>
```

The plugin loads and serves in this mode. The repo's test lane starts it this way. Each start writes a new token to `res://.godot/godot_mcp/headers.json`, so reconnect the client after a restart.

## Setup

- In the editor, choose Project > Tools > "MCP: install agent skill / show config". The dialog writes `.claude/skills/godot-mcp/SKILL.md` and shows the `.mcp.json` entry. Copy that entry into `.mcp.json`. The Copy button puts it on the clipboard.
- `install_agent_skill` does the same from the agent side. It returns the entry, and it refuses a `SKILL.md` without the godot_mcp marker unless `overwrite` is true.
- Run setup again after you upgrade the addon. It rewrites `SKILL.md` when the copy differs.
- Setup never writes `.mcp.json`, and it never writes the token. Don't write either by hand.
- Setup is POSIX only. Windows gets `UNSUPPORTED_PLATFORM`. It also refuses a link in the install path, and a project path that contains `${` or a control character.
