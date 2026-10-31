import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { copyFile } from "node:fs/promises";
import { join } from "node:path";
import {
  freePort,
  godotBin,
  prepareProject,
  removeProjects,
} from "./harness.ts";

// Runs probes/dispatch_probe.gd, which drives the addon's HttpServer and McpServer in-process with the
// execution budget and write deadline patched down to 600 ms. These checks need timings the real
// editor can't show quickly: the D37 handler cancel, the queued deadline, the write deadline against
// a reader that never drains, the reply-shape guard, and empty tool results.

const expected = [
  "empty result is a success",
  "nothing result is INTERNAL",
  "array result is INTERNAL",
  "broken result is INTERNAL",
  "objects in containers are references",
  "printerr is logged as error",
  "a cursor ahead of the log resets",
  "a departing client cancels its handler",
  "reply shape null gets 500",
  "reply shape short gets 500",
  "reply shape badtype gets 500",
  "timed-out handler gets 500",
  "the next request is served",
  "handlers never overlap",
  "a second client is served during the stall",
  "the stalled peer is closed at the write deadline",
  "a queued request gets 500 at the deadline",
  "the queued request never started",
  "an image block follows the text block",
  "_content is not in structuredContent or the text",
  "a textblock _content is INTERNAL",
  "a badmime _content is INTERNAL",
  "a notarray _content is INTERNAL",
  "a extrakey _content is INTERNAL",
  "a nonstring _content is INTERNAL",
];

const results = new Map<string, { ok: boolean; detail: string }>();
let exitCode = -1;
let output = "";

beforeAll(async () => {
  const dir = await prepareProject(await freePort());
  await copyFile(
    join(import.meta.dir, "probes", "dispatch_probe.gd"),
    join(dir, "dispatch_probe.gd"),
  );
  const child = Bun.spawn(
    [godotBin(), "--headless", "--path", dir, "-s", "res://dispatch_probe.gd"],
    { stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  );
  const [out, err] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  exitCode = await child.exited;
  output = out + err;
  for (const line of out.split("\n")) {
    if (!line.startsWith("PROBE ")) continue;
    const parsed = JSON.parse(line.slice("PROBE ".length));
    results.set(parsed.name, parsed);
  }
}, 120_000);

afterAll(removeProjects);

describe("dispatcher probe", () => {
  for (const name of expected) {
    test(name, () => {
      const result = results.get(name);
      if (result === undefined)
        throw new Error(`the probe did not report this check:\n${output}`);
      expect(result.ok, result.detail).toBe(true);
    });
  }

  test("a reply with control characters is strict JSON", () => {
    const raw = results.get("control characters reply")?.detail;
    if (raw === undefined) throw new Error(`no reply:\n${output}`);
    const expectedText = "\u0001\u000b\u001b\\v\\\\v";
    const reply = JSON.parse(raw);
    expect(reply.result.structuredContent.s).toBe(expectedText);
    expect(JSON.parse(reply.result.content[0].text).s).toBe(expectedText);
  });

  test("the probe exits 0", () => {
    expect(exitCode, output).toBe(0);
  });
});
