import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { waitFor } from "../helpers.ts";
import {
  callTool,
  type Editor,
  failure as failureOn,
  freePort,
  ok as okOn,
  prepareProject,
  removeProjects,
  startEditor,
} from "./harness.ts";

// enable_plugin, disable_plugin and get_project_info.plugins against a real editor (plan slice 1).

let editor: Editor;

beforeAll(async () => {
  const port = await freePort();
  const dir = await prepareProject(port);
  await symlink(join(dir, "addons", "marker"), join(dir, "addons", "linked"));
  await mkdir(join(dir, "addons", "vendor", "nested"), { recursive: true });
  await writeFile(
    join(dir, "addons", "vendor", "nested", "plugin.cfg"),
    '[plugin]\n\nname="Nested"\nscript="nested.gd"\n',
  );
  editor = await startEditor({ dir, port });
  await waitFor(async () => {
    const info = await callTool(editor, "get_project_info");
    return info.structuredContent.scanning === false ? true : undefined;
  }, 60_000);
}, 180_000);

afterAll(async () => {
  await editor?.stop();
  await removeProjects();
});

const ok = (name: string, args: Record<string, unknown> = {}) =>
  okOn(editor, name, args);
const failure = (name: string, args: Record<string, unknown> = {}) =>
  failureOn(editor, name, args);

const markerState = () =>
  readFile(join(editor.dir, "marker_state.txt"), "utf8");
const projectFile = () => readFile(join(editor.dir, "project.godot"), "utf8");
const enabledOnDisk = async () =>
  (await projectFile()).includes("res://addons/marker/plugin.cfg");

async function errorCount(): Promise<number> {
  const log = await ok("get_editor_log", { level: "error", limit: 1000 });
  return log.entries.length + log.dropped;
}

async function plugins(): Promise<Record<string, boolean>> {
  const info = await ok("get_project_info");
  return Object.fromEntries(
    info.plugins.map((p: { name: string; enabled: boolean }) => [
      p.name,
      p.enabled,
    ]),
  );
}

describe("get_project_info.plugins", () => {
  test("lists each plugin folder with its enabled flag and version, skipping links", async () => {
    const info = await ok("get_project_info");
    expect(info.plugins).toEqual([
      { name: "broken_plugin", enabled: false, version: "0.0.1" },
      { name: "godot_mcp", enabled: true, version: "0.1.0" },
      { name: "marker", enabled: false, version: "1.2.3" },
      { name: "no_script", enabled: false, version: "1.0" },
      { name: "vendor/nested", enabled: false, version: null },
    ]);
  });
});

describe("enable_plugin and disable_plugin", () => {
  test("enable runs _enter_tree and writes project.godot before returning; a repeat changes nothing", async () => {
    expect(await enabledOnDisk()).toBe(false);
    const first = await ok("enable_plugin", { name: "marker" });
    expect(first).toEqual({
      name: "marker",
      path: "res://addons/marker/plugin.cfg",
      enabled: true,
      changed: true,
    });
    expect(await markerState()).toBe("enter");
    expect(await enabledOnDisk()).toBe(true);
    expect((await plugins()).marker).toBe(true);

    const errors = await errorCount();
    const second = await ok("enable_plugin", { name: "marker" });
    expect(second.changed).toBe(false);
    expect(await errorCount()).toBe(errors);
  });

  test("disable runs _exit_tree and removes the entry from disk; a repeat changes nothing", async () => {
    const first = await ok("disable_plugin", { name: "marker" });
    expect(first.enabled).toBe(false);
    expect(first.changed).toBe(true);
    expect(await markerState()).toBe("exit");
    expect(await enabledOnDisk()).toBe(false);
    expect((await plugins()).marker).toBe(false);

    const errors = await errorCount();
    const second = await ok("disable_plugin", { name: "marker" });
    expect(second.changed).toBe(false);
    expect(await errorCount()).toBe(errors);
  });

  test("a nested plugin folder is addressed by its relative path", async () => {
    const result = await callTool(editor, "enable_plugin", {
      name: "vendor/nested",
    });
    // Its script does not exist, so the editor refuses; the path form was accepted.
    expect(result.structuredContent.error.code).toBe("PLUGIN_FAILED");
    expect(result.structuredContent.error.message).toContain(
      "res://addons/vendor/nested/plugin.cfg",
    );
  });

  for (const tool of ["enable_plugin", "disable_plugin"]) {
    test(`${tool} refuses the godot_mcp addon in any case and the server keeps answering`, async () => {
      for (const name of ["godot_mcp", "GODOT_MCP"])
        expect(await failure(tool, { name })).toBe("PROTECTED_PATH");
      expect((await plugins()).godot_mcp).toBe(true);
    });
  }

  test("a script with a parse error gives PLUGIN_FAILED naming the script, and stays disabled", async () => {
    const result = await callTool(editor, "enable_plugin", {
      name: "broken_plugin",
    });
    expect(result.isError).toBe(true);
    expect(result.structuredContent.error.code).toBe("PLUGIN_FAILED");
    expect(result.structuredContent.error.message).toContain("broken.gd");
    expect((await plugins()).broken_plugin).toBe(false);
  });

  test("a cfg without a script key gives PLUGIN_FAILED before the editor is asked", async () => {
    const errors = await errorCount();
    expect(await failure("enable_plugin", { name: "no_script" })).toBe(
      "PLUGIN_FAILED",
    );
    expect(await errorCount()).toBe(errors);
  });

  for (const [label, name, code] of [
    ["a missing plugin", "missing", "FILE_NOT_FOUND"],
    ["a .. segment", "../x", "INVALID_PATH"],
    ["a backslash", "a\\b", "INVALID_PATH"],
    ["a symlinked folder", "linked", "INVALID_PATH"],
  ] as const) {
    for (const tool of ["enable_plugin", "disable_plugin"])
      test(`${tool} gives ${code} for ${label}`, async () => {
        expect(await failure(tool, { name })).toBe(code);
      });
  }
});

describe("set_project_setting", () => {
  test("still refuses editor_plugins/enabled", async () => {
    expect(
      await failure("set_project_setting", {
        name: "editor_plugins/enabled",
        value: [],
      }),
    ).toBe("PROTECTED_SETTING");
  });
});

// broken_plugin's parse errors are the point of that test; the engine prints each as a SCRIPT ERROR
// line followed by an "at:" line naming the script. Any other script error is a defect.
test("the editor printed no SCRIPT ERROR except the broken plugin's", () => {
  const lines = editor.output().split("\n");
  const stray = lines.filter(
    (line, i) =>
      line.includes("SCRIPT ERROR") && !lines[i + 1]?.includes("broken.gd"),
  );
  expect(stray).toEqual([]);
});
