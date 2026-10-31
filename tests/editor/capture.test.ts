import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { copyFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { waitFor } from "../helpers.ts";
import {
  callTool,
  type Editor,
  failure as failureOn,
  freePort,
  godotBin,
  ok as okOn,
  prepareProject,
  removeProjects,
  startEditor,
} from "./harness.ts";

// capture_viewport (plan slice 3). The headless lane has no renderer, so pixels are an operator
// check. probes/capture_probe.gd covers the reply-path checks, the copy, the rotation and the inline
// image outside the editor; the editor tests prove the request reaches the game through the game's
// own error line.

const expected = [
  "a valid reply is copied to the captures folder",
  "the game's temp file is removed after the copy",
  "the inline block is the PNG",
  "a 21st capture deletes the oldest",
  "rotation never deletes the capture just written",
  "a path outside the temp folder is CAPTURE_FAILED and left alone",
  "a wrong name is CAPTURE_FAILED and left alone",
  "a name with a non-digit is CAPTURE_FAILED and left alone",
  "a path with a .. segment is CAPTURE_FAILED and left alone",
  "a symbolic link is CAPTURE_FAILED and left alone",
  "a non-PNG file is CAPTURE_FAILED and left alone",
  "a directory is CAPTURE_FAILED and left alone",
  "a reply without a path is refused",
  "a refused link's target is untouched",
  "a custom path is written, with no inline block when inline is false",
  "a custom path that appeared meanwhile is FILE_EXISTS",
  "a 4000x3000 capture is inlined at most 1568 px on the long side",
  "a capture whose PNG is over 2 MB is inlined as JPEG",
  "a PNG over the pixel cap is CAPTURE_FAILED and left alone",
  "a file over 64 MB is CAPTURE_FAILED and left alone",
  "a linked captures folder is refused and nothing is written there",
  "a reply with an id below 2^40 is not claimed",
  "a reply with an id not yet issued is not claimed",
  "other game_view messages are not claimed",
  "a reply to an issued id is claimed",
];

const results = new Map<string, { ok: boolean; detail: string }>();
let exitCode = -1;
let probeOutput = "";
let editor: Editor;

beforeAll(async () => {
  const probeDir = await prepareProject(null);
  await copyFile(
    join(import.meta.dir, "probes", "capture_probe.gd"),
    join(probeDir, "capture_probe.gd"),
  );
  const child = Bun.spawn(
    [
      godotBin(),
      "--headless",
      "--path",
      probeDir,
      "-s",
      "res://capture_probe.gd",
    ],
    { stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  );
  const [out, err] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  exitCode = await child.exited;
  probeOutput = out + err;
  for (const line of out.split("\n")) {
    if (!line.startsWith("PROBE ")) continue;
    const parsed = JSON.parse(line.slice("PROBE ".length));
    results.set(parsed.name, parsed);
  }

  const port = await freePort();
  const dir = await prepareProject(port);
  await writeFile(join(dir, "existing.png"), "x");
  editor = await startEditor({ dir, port });
  await waitFor(async () => {
    const info = await callTool(editor, "get_project_info");
    return info.structuredContent.scanning === false ? true : undefined;
  }, 60_000);
}, 240_000);

afterAll(async () => {
  await editor?.stop();
  await removeProjects();
});

const ok = (name: string, args: Record<string, unknown> = {}) =>
  okOn(editor, name, args);
const failure = (name: string, args: Record<string, unknown> = {}) =>
  failureOn(editor, name, args);

describe("capture probe", () => {
  for (const name of expected) {
    test(name, () => {
      const result = results.get(name);
      if (result === undefined)
        throw new Error(`the probe did not report this check:\n${probeOutput}`);
      expect(result.ok, result.detail).toBe(true);
    });
  }

  test("the probe exits 0 with no SCRIPT ERROR", () => {
    expect(exitCode, probeOutput).toBe(0);
    expect(probeOutput).not.toContain("SCRIPT ERROR");
  });
});

describe("capture_viewport in the editor", () => {
  test("with nothing playing it fails with NO_GAME at once", async () => {
    const started = Date.now();
    expect(await failure("capture_viewport")).toBe("NO_GAME");
    expect(Date.now() - started).toBeLessThan(1000);
  });

  test("path rules are checked before anything else", async () => {
    expect(
      await failure("capture_viewport", { path: "res://existing.png" }),
    ).toBe("FILE_EXISTS");
    expect(
      await failure("capture_viewport", {
        path: "res://addons/godot_mcp/x.png",
      }),
    ).toBe("PROTECTED_PATH");
    expect(
      await failure("capture_viewport", {
        path: "res://ADDONS/GODOT_MCP/x.png",
      }),
    ).toBe("PROTECTED_PATH");
    expect(await failure("capture_viewport", { path: "res://x.jpg" })).toBe(
      "INVALID_PATH",
    );
    expect(
      await failure("capture_viewport", {
        path: "res://.godot/godot_mcp/captures/x.png",
      }),
    ).toBe("INVALID_PATH");
  });

  test("a headless game gets the request and has no image to send", async () => {
    await ok("play_scene", { mode: "main" });
    try {
      expect(await failure("capture_viewport", { timeoutSec: 3 })).toBe(
        "CAPTURE_TIMEOUT",
      );
      // The game inherits the editor's stdio, so its error proves the request arrived.
      await waitFor(
        () =>
          editor
            .output()
            .includes("Cannot get an image from a viewport texture")
            ? true
            : undefined,
        5000,
      );
    } finally {
      await ok("stop_scene");
    }
    expect(await failure("capture_viewport")).toBe("NO_GAME");
  }, 30_000);

  test("the editor printed no SCRIPT ERROR", () => {
    expect(editor.output()).not.toContain("SCRIPT ERROR");
  });
});
