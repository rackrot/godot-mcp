import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
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

// add_input_action against a real editor (plan slice 2). Behavior is asserted from the game's side:
// input_probe.gd runs through run_headless, so it reads project.godot the way a game does at start.

let editor: Editor;

beforeAll(async () => {
  const port = await freePort();
  const dir = await prepareProject(port);
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
const add = (name: string, events: unknown[], more = {}) =>
  ok("add_input_action", { name, events, ...more });
const projectFile = () => readFile(join(editor.dir, "project.godot"), "utf8");

const KEY_P = 80;
const KEY_F1 = 4194332;
const KEY_1 = 49;
const MOUSE_RIGHT = 2;

interface Seen {
  action: string;
  exists: boolean;
  deadzone?: number;
  matches?: boolean;
  events?: Record<string, unknown>[];
}

// What a game process sees for these actions.
async function seen(...actions: string[]): Promise<Record<string, Seen>> {
  const result = await ok("run_headless", {
    script: "res://input_probe.gd",
    userArgs: actions,
  });
  expect(result.ok).toBe(true);
  const out: Record<string, Seen> = {};
  for (const line of result.stdoutTail.split("\n")) {
    if (!line.startsWith("ACTION:")) continue;
    const one: Seen = JSON.parse(line.slice("ACTION:".length));
    out[one.action] = one;
  }
  return out;
}

const noModifiers = {
  ctrl: false,
  shift: false,
  alt: false,
  meta: false,
  autoremap: false,
};

const physicalKey = (code: number, modifiers = {}) => ({
  class: "InputEventKey",
  device: -1,
  physicalKeycode: code,
  keycode: 0,
  ...noModifiers,
  ...modifiers,
});

describe("what the game sees", () => {
  test("Ctrl+P is one physical key with Ctrl, all devices, deadzone 0.2, and matches a device-0 press", async () => {
    const result = await add("debug_toggle", ["Ctrl+P"]);
    expect(result).toMatchObject({
      name: "debug_toggle",
      created: true,
      deadzone: 0.2,
      previous: null,
      editorRefreshed: expect.any(Boolean),
    });
    expect(result.events).toEqual([
      {
        type: "key",
        key: "P",
        modifiers: ["Ctrl"],
        physical: true,
        device: -1,
      },
    ]);
    const game = await seen("debug_toggle");
    // The InputMap stores the deadzone as a 32-bit float.
    expect(game.debug_toggle?.deadzone).toBeCloseTo(0.2, 6);
    expect(game.debug_toggle).toMatchObject({
      exists: true,
      events: [physicalKey(KEY_P, { ctrl: true })],
      matches: true,
    });
  }, 60_000);

  test("F1 to F5 and Alt+1 to Alt+5 each arrive with their code and modifier", async () => {
    const names: string[] = [];
    for (let n = 1; n <= 5; n++) {
      await add(`fn_${n}`, [`F${n}`]);
      await add(`alt_${n}`, [`Alt+${n}`]);
      names.push(`fn_${n}`, `alt_${n}`);
    }
    const game = await seen(...names);
    for (let n = 1; n <= 5; n++) {
      expect(game[`fn_${n}`]?.events).toEqual([physicalKey(KEY_F1 + n - 1)]);
      expect(game[`alt_${n}`]?.events).toEqual([
        physicalKey(KEY_1 + n - 1, { alt: true }),
      ]);
    }
  }, 60_000);

  test("object forms: mouse button with Shift, joypad button, logical key, CmdOrCtrl and a device", async () => {
    await add("objects", [
      { type: "mouseButton", button: "right", modifiers: ["Shift"] },
      { type: "joypadButton", button: 0 },
      { type: "key", key: "Space", physical: false },
      { type: "key", key: "S", modifiers: ["cmdorctrl"] },
      { type: "joypadButton", button: 127, device: 1 },
    ]);
    const game = await seen("objects");
    expect(game.objects?.events).toEqual([
      {
        class: "InputEventMouseButton",
        device: -1,
        buttonIndex: MOUSE_RIGHT,
        ...noModifiers,
        shift: true,
      },
      { class: "InputEventJoypadButton", device: -1, buttonIndex: 0 },
      {
        class: "InputEventKey",
        device: -1,
        physicalKeycode: 0,
        keycode: 32,
        ...noModifiers,
      },
      // The setter also sets the platform's own modifier, which differs between systems.
      expect.objectContaining({
        class: "InputEventKey",
        physicalKeycode: 83,
        autoremap: true,
      }),
      { class: "InputEventJoypadButton", device: 1, buttonIndex: 127 },
    ]);
  }, 60_000);
});

describe("replace and append", () => {
  test("replace leaves only the new events, keeps the deadzone and reports the previous ones", async () => {
    const result = await add("debug_toggle", ["F6"]);
    expect(result.created).toBe(false);
    expect(result.deadzone).toBe(0.2);
    expect(result.previous).toEqual({
      deadzone: 0.2,
      events: [
        {
          type: "key",
          key: "P",
          modifiers: ["Ctrl"],
          physical: true,
          device: -1,
        },
      ],
    });
    const game = await seen("debug_toggle");
    expect(game.debug_toggle?.events).toEqual([physicalKey(KEY_F1 + 5)]);
    expect(game.debug_toggle?.deadzone).toBeCloseTo(0.2, 6);
    // Ctrl+P no longer triggers it.
    expect(game.debug_toggle?.matches).toBe(false);
  }, 60_000);

  test("previous names CmdOrCtrl once, not also the platform's own modifier", async () => {
    await add("remapped", [
      { type: "key", key: "S", modifiers: ["CmdOrCtrl", "Shift"] },
    ]);
    const result = await add("remapped", []);
    expect(result.previous.events[0].modifiers).toEqual(["Shift", "CmdOrCtrl"]);
  }, 60_000);

  test("append adds only the events the action lacks, so a repeat changes nothing", async () => {
    await add("debug_toggle", ["F6", "F7"], { append: true });
    await add("debug_toggle", ["F7", "f6"], { append: true });
    const game = await seen("debug_toggle");
    expect(game.debug_toggle?.events).toEqual([
      physicalKey(KEY_F1 + 5),
      physicalKey(KEY_F1 + 6),
    ]);
  }, 60_000);

  test("the same key as a physical and a logical event are different bindings", async () => {
    await add("debug_toggle", [{ type: "key", key: "F6", physical: false }], {
      append: true,
    });
    expect((await seen("debug_toggle")).debug_toggle?.events).toHaveLength(3);
  }, 60_000);

  test("an explicit deadzone replaces the old one, and later calls keep it", async () => {
    expect(
      (await add("debug_toggle", ["F8"], { deadzone: 0.75 })).deadzone,
    ).toBe(0.75);
    expect((await add("debug_toggle", ["F9"])).deadzone).toBe(0.75);
    expect((await seen("debug_toggle")).debug_toggle?.deadzone).toBe(0.75);
  }, 60_000);

  test("events: [] empties the action but it still exists", async () => {
    const result = await add("debug_toggle", []);
    expect(result.events).toEqual([]);
    const game = await seen("debug_toggle");
    expect(game.debug_toggle).toMatchObject({ exists: true, events: [] });
  }, 60_000);

  test("a built-in action can be replaced", async () => {
    const result = await add("ui_cancel", ["Q"]);
    expect(result.created).toBe(false);
    expect(result.previous.events.length).toBeGreaterThan(0);
    const game = await seen("ui_cancel");
    expect(game.ui_cancel?.events).toEqual([physicalKey(81)]);
  }, 60_000);
});

describe("refusals", () => {
  const cases: [string, Record<string, unknown>, string][] = [
    ["an unknown modifier", { events: ["Hyper+P"] }, "INVALID_VALUE"],
    ["a repeated modifier", { events: ["Ctrl+Ctrl+P"] }, "INVALID_VALUE"],
    ["a missing key", { events: ["Ctrl+"] }, "INVALID_VALUE"],
    ["an unknown key", { events: ["Ctrl+NoSuchKey"] }, "INVALID_VALUE"],
    [
      "modifiers hidden in the key field",
      { events: [{ type: "key", key: "Hyper+P" }] },
      "INVALID_VALUE",
    ],
    [
      "an unknown event field",
      { events: [{ type: "key", key: "P", physcial: true }] },
      "INVALID_VALUE",
    ],
    ["an unknown event type", { events: [{ type: "touch" }] }, "INVALID_VALUE"],
    ["a number as an event", { events: [5] }, "INVALID_VALUE"],
    [
      "a joypad button over 127",
      { events: [{ type: "joypadButton", button: 128 }] },
      "INVALID_VALUE",
    ],
    [
      "an unknown mouse button",
      { events: [{ type: "mouseButton", button: "Left" }] },
      "INVALID_VALUE",
    ],
    [
      "a device below -1",
      { events: [{ type: "joypadButton", button: 0, device: -2 }] },
      "INVALID_VALUE",
    ],
    [
      "33 events",
      { events: Array.from({ length: 33 }, (_, i) => `F${(i % 12) + 1}`) },
      "INVALID_VALUE",
    ],
    ["a slash in the name", { name: "a/b", events: ["F1"] }, "INVALID_NAME"],
    [
      "an equals sign in the name",
      { name: "a=b", events: ["F1"] },
      "INVALID_NAME",
    ],
    [
      "a space at the end of the name",
      { name: "a ", events: ["F1"] },
      "INVALID_NAME",
    ],
    [
      "a control character in the name",
      { name: "a\nb", events: ["F1"] },
      "INVALID_NAME",
    ],
  ];
  for (const [label, args, code] of cases)
    test(`${label} gives ${code} and project.godot is unchanged`, async () => {
      const before = await projectFile();
      const full = { name: "refused", events: ["F1"], ...args };
      expect(await failure("add_input_action", full)).toBe(code);
      expect(await projectFile()).toBe(before);
    });

  test("a deadzone over 1 and a non-array events are schema errors", async () => {
    const before = await projectFile();
    for (const args of [
      { name: "refused", events: ["F1"], deadzone: 1.5 },
      { name: "refused", events: "F1" },
    ]) {
      const res = await fetch(`http://127.0.0.1:${editor.port}/mcp`, {
        method: "POST",
        headers: {
          Authorization: editor.auth,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: { name: "add_input_action", arguments: args },
        }),
      });
      expect((await res.json()).error.code).toBe(-32602);
    }
    expect(await projectFile()).toBe(before);
  });

  test("a refused call creates no action in the game", async () => {
    expect((await seen("refused")).refused?.exists).toBe(false);
  }, 60_000);
});

describe("set_project_setting and input/", () => {
  test("input/ is refused in any case, and input_devices/ is still settable", async () => {
    for (const name of ["input/foo", "Input/Foo"])
      expect(await failure("set_project_setting", { name, value: {} })).toBe(
        "PROTECTED_SETTING",
      );
    const result = await ok("set_project_setting", {
      name: "input_devices/pointing/emulate_touch_from_mouse",
      value: true,
    });
    expect(result.value.value).toBe(true);
  });
});

test("the editor printed no SCRIPT ERROR", () => {
  expect(editor.output()).not.toContain("SCRIPT ERROR");
});
