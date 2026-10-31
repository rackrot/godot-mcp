import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  lstat,
  mkdir,
  readdir,
  readFile,
  readlink,
  symlink,
} from "node:fs/promises";
import { basename, join } from "node:path";
import {
  Client,
  StreamableHTTPClientTransport,
} from "@modelcontextprotocol/client";
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
import { type ZipEntry, zip } from "./zip.ts";

// install_asset against a real editor (plan slice 4). The Asset Library is a loopback Bun.serve that
// the editor reaches through the GODOT_MCP_ASSET_LIBRARY_URL seam; no test touches the network.

type Server = ReturnType<typeof Bun.serve>;

let editor: Editor;
let library: Server;
// A second loopback server that no download may reach.
let foreign: Server;
let origin: string;
const hits: string[] = [];
const foreignHits: string[] = [];
const records = new Map<string, Record<string, unknown>>();
const routes = new Map<string, () => Response>();

beforeAll(async () => {
  library = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      const path = new URL(req.url).pathname;
      hits.push(path);
      const asset = /^\/api\/asset\/(\d+)$/.exec(path)?.[1];
      if (asset !== undefined) {
        const record = records.get(asset);
        return record === undefined
          ? new Response("{}", { status: 404 })
          : Response.json(record);
      }
      return routes.get(path)?.() ?? new Response("missing", { status: 404 });
    },
  });
  foreign = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      foreignHits.push(new URL(req.url).pathname);
      return new Response("foreign");
    },
  });
  origin = `http://127.0.0.1:${library.port}`;
  const port = await freePort();
  const dir = await prepareProject(port);
  editor = await startEditor({
    dir,
    port,
    env: { GODOT_MCP_ASSET_LIBRARY_URL: `${origin}/api` },
  });
  await idle();
}, 180_000);

afterAll(async () => {
  await editor?.stop();
  await removeProjects();
  library?.stop(true);
  foreign?.stop(true);
});

const ok = (name: string, args: Record<string, unknown> = {}) =>
  okOn(editor, name, args);
const failure = (name: string, args: Record<string, unknown> = {}) =>
  failureOn(editor, name, args);

async function idle(): Promise<void> {
  await waitFor(async () => {
    const info = await callTool(editor, "get_project_info");
    return info.structuredContent.scanning === false ? true : undefined;
  }, 60_000);
}

let nextId = 1000;

// Serves `archive` as a new asset and returns its id. `record` overrides the API record's fields.
function publish(
  archive: Uint8Array<ArrayBuffer> | null,
  record: Record<string, unknown> = {},
): number {
  const id = ++nextId;
  if (archive !== null)
    routes.set(`/files/${id}.zip`, () => new Response(archive));
  records.set(String(id), {
    asset_id: String(id),
    type: "addon",
    title: `Asset ${id}`,
    version_string: "1.0.0",
    godot_version: "4.2",
    cost: "MIT",
    download_provider: "Custom",
    download_commit: "",
    download_url: `${origin}/files/${id}.zip`,
    download_hash: "",
    ...record,
  });
  return id;
}

const sha256 = (bytes: Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");

// Every path under the project except .godot/, with a digest of each file and the target of each link.
async function tree(): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  const walk = async (relative: string) => {
    for (const entry of await readdir(join(editor.dir, relative), {
      withFileTypes: true,
    })) {
      const path = relative === "" ? entry.name : `${relative}/${entry.name}`;
      if (path === ".godot") continue;
      const full = join(editor.dir, path);
      if (entry.isSymbolicLink()) out[path] = `link:${await readlink(full)}`;
      else if (entry.isDirectory()) {
        out[path] = "dir";
        await walk(path);
      } else out[path] = sha256(await readFile(full));
    }
  };
  await walk("");
  return out;
}

async function stateDir(name: string): Promise<string[]> {
  return await readdir(join(editor.dir, ".godot", "godot_mcp", name)).catch(
    () => [],
  );
}

// The error code of an install that must fail, after checking that it wrote nothing outside .godot/
// and left no download or stage behind.
async function refused(args: Record<string, unknown>): Promise<string> {
  const before = await tree();
  const code = await failure("install_asset", args);
  expect(await tree()).toEqual(before);
  expect(await stateDir("downloads")).toEqual([]);
  expect(await stateDir("staging")).toEqual([]);
  return code;
}

const pluginCfg = (script: string) =>
  `[plugin]\n\nname="Hello"\ndescription=""\nauthor=""\nversion="1.0"\nscript="${script}"\n`;
const pluginScript = "@tool\nextends EditorPlugin\n";

// An addon `x` with one script, under `prefix`, plus the given extra entries.
const withAddon = (extra: ZipEntry[], prefix = "") =>
  zip([{ name: `${prefix}addons/x/ok.gd`, data: "extends Node\n" }, ...extra]);

describe("install_asset", () => {
  let happyZip: Uint8Array<ArrayBuffer>;
  let happyId: number;

  test("installs only the addons/ subtree of a GitHub-style archive, after a redirect", async () => {
    happyZip = zip([
      { name: "repo-abc/" },
      { name: "repo-abc/addons/" },
      { name: "repo-abc/addons/hello/" },
      { name: "repo-abc/addons/hello/plugin.cfg", data: pluginCfg("hello.gd") },
      { name: "repo-abc/addons/hello/hello.gd", data: pluginScript, method: 0 },
      { name: "repo-abc/README.md", data: "# readme\n" },
      { name: "repo-abc/project.godot", data: "config_version=5\n" },
      { name: "repo-abc/override.cfg", data: "[application]\n" },
    ]);
    happyId = publish(happyZip, {
      download_url: `${origin}/redirect/hello`,
    });
    routes.set(
      "/redirect/hello",
      () =>
        new Response(null, {
          status: 302,
          headers: { Location: `/files/${happyId}.zip` },
        }),
    );
    const before = await tree();
    const result = await ok("install_asset", { assetId: happyId });
    expect(result).toMatchObject({
      ok: true,
      assetId: happyId,
      versionString: "1.0.0",
      license: "MIT",
      downloadUrl: `${origin}/redirect/hello`,
      finalUrl: `${origin}/files/${happyId}.zip`,
      sha256: sha256(happyZip),
      bytes: happyZip.length,
      addons: ["hello"],
      plugins: ["hello"],
      files: 2,
      needsDotnetBuild: false,
      backups: [],
      warnings: [],
      errorCount: 0,
    });
    const after = await tree();
    const added = Object.keys(after).filter((path) => !(path in before));
    expect(
      added.every(
        (path) => path === "addons/hello" || path.startsWith("addons/hello/"),
      ),
    ).toBe(true);
    expect(added).toContain("addons/hello/plugin.cfg");
    expect(added).toContain("addons/hello/hello.gd");
    for (const path of Object.keys(before))
      expect(after[path]).toBe(before[path] as string);
    expect(
      await readFile(join(editor.dir, "addons/hello/hello.gd"), "utf8"),
    ).toBe(pluginScript);
    expect(await stateDir("downloads")).toEqual([]);
    expect(await stateDir("staging")).toEqual([]);

    // Installing never enables; enabling the result works.
    expect((await ok("enable_plugin", { name: "hello" })).changed).toBe(true);
  }, 60_000);

  test("an existing addon gives FILE_EXISTS, and an enabled one PLUGIN_ENABLED even with overwrite", async () => {
    expect(await refused({ assetId: happyId })).toBe("FILE_EXISTS");
    expect(await refused({ assetId: happyId, overwrite: true })).toBe(
      "PLUGIN_ENABLED",
    );
  }, 60_000);

  test("overwrite swaps the folder and keeps the old one as a backup", async () => {
    await ok("disable_plugin", { name: "hello" });
    const id = publish(
      zip([
        { name: "addons/hello/plugin.cfg", data: pluginCfg("new.gd") },
        { name: "addons/hello/new.gd", data: pluginScript },
      ]),
    );
    const result = await ok("install_asset", { assetId: id, overwrite: true });
    expect(result.backups).toHaveLength(1);
    const backup: string = result.backups[0];
    expect(backup).toMatch(/^res:\/\/\.godot\/godot_mcp\/backups\/hello-\d+$/);
    const addon = join(editor.dir, "addons", "hello");
    expect((await readdir(addon)).sort()).toContain("new.gd");
    expect(await readdir(addon)).not.toContain("hello.gd");
    const kept = join(editor.dir, backup.replace("res://", ""));
    expect(await readFile(join(kept, "hello.gd"), "utf8")).toBe(pluginScript);
  }, 60_000);

  test("only the newest 5 backups are kept, and pruning never follows a link", async () => {
    const backups = join(editor.dir, ".godot", "godot_mcp", "backups");
    const marker = join(editor.dir, "addons", "marker");
    const markerFiles = (await readdir(marker)).sort();
    const earlier = await readdir(backups);
    expect(earlier).toHaveLength(1);
    for (let stamp = 1; stamp <= 6; stamp++)
      await mkdir(join(backups, `old-${stamp}`));
    await symlink(marker, join(backups, "old-1", "dir-link"));
    await symlink(
      join(marker, "plugin.cfg"),
      join(backups, "old-1", "file-link"),
    );
    const id = publish(
      zip([{ name: "addons/hello/plugin.cfg", data: pluginCfg("new.gd") }]),
    );
    const result = await ok("install_asset", { assetId: id, overwrite: true });
    const newest = basename(String(result.backups[0]));
    // The overwrite test's backup and this one are newer than old-6.
    expect((await readdir(backups)).sort()).toEqual(
      [...earlier, newest, "old-4", "old-5", "old-6"].sort(),
    );
    expect((await readdir(marker)).sort()).toEqual(markerFiles);
  }, 60_000);

  for (const [label, entries] of [
    ["a .. segment", [{ name: "addons/x/../../evil.gd", data: "x" }]],
    ["a leading slash", [{ name: "/addons/x/a.gd", data: "x" }]],
    ["backslashes", [{ name: "addons\\x\\a.gd", data: "x" }]],
    ["a . segment", [{ name: "addons/x/./a.gd", data: "x" }]],
    ["an empty segment", [{ name: "addons/x//a.gd", data: "x" }]],
    ["a colon", [{ name: "addons/x/c:a.gd", data: "x" }]],
    [
      "a symlink entry",
      [{ name: "addons/x/link", data: "../../project.godot", mode: 0o120777 }],
    ],
    [
      "names that collide when lowercased",
      [
        { name: "Addons/X/a.gd", data: "x" },
        { name: "addons/x/a.gd", data: "x" },
      ],
    ],
    ["a control character", [{ name: "addons/x/a\x01.gd", data: "x" }]],
    ["an encrypted entry", [{ name: "addons/x/a.gd", data: "x", flags: 1 }]],
    [
      "a name that is not UTF-8",
      [{ name: new Uint8Array([0x61, 0x2f, 0xff, 0x2e]), data: "x" }],
    ],
    ["a duplicate name", [{ name: "addons/x/ok.gd", data: "y" }]],
    [
      "a file that is also a folder",
      [
        { name: "addons/y", data: "x" },
        { name: "addons/y/a.gd", data: "x" },
      ],
    ],
    [
      "a declared size smaller than the data",
      [{ name: "addons/x/big.gd", data: "x".repeat(4000), declaredSize: 10 }],
    ],
  ] as [string, ZipEntry[]][]) {
    test(`ZIP_UNSAFE for ${label}, with nothing written`, async () => {
      const id = publish(withAddon(entries));
      expect(await refused({ assetId: id })).toBe("ZIP_UNSAFE");
    }, 30_000);
  }

  test("a 2 GB declared entry is refused before extraction, without the memory", async () => {
    const status = async () =>
      Number(
        /VmHWM:\s+(\d+) kB/.exec(
          await readFile(`/proc/${editor.pid}/status`, "utf8"),
        )?.[1],
      );
    const peak = await status();
    const id = publish(
      withAddon([
        {
          name: "addons/x/bomb.bin",
          data: new Uint8Array(64 * 1024),
          declaredSize: 2 ** 31,
        },
      ]),
    );
    expect(await refused({ assetId: id })).toBe("ZIP_UNSAFE");
    expect((await ok("get_project_info")).jobActive).toBe(false);
    expect((await status()) - peak).toBeLessThan(256 * 1024);
  }, 30_000);

  test("a body over 64 MiB gives TOO_LARGE, with Content-Length and chunked", async () => {
    const big = new Uint8Array(65 * 1024 * 1024);
    const sized = publish(null);
    routes.set(`/files/${sized}.zip`, () => new Response(big));
    expect(await refused({ assetId: sized })).toBe("TOO_LARGE");

    const chunked = publish(null);
    routes.set(`/files/${chunked}.zip`, () => {
      let sent = 0;
      return new Response(
        new ReadableStream({
          pull(controller) {
            if (sent >= 65) return controller.close();
            sent++;
            controller.enqueue(new Uint8Array(1024 * 1024));
          },
        }),
      );
    });
    expect(await refused({ assetId: chunked })).toBe("TOO_LARGE");
  }, 60_000);

  test("downloads and redirects off the allowed hosts are refused before connecting", async () => {
    const archive = withAddon([]);
    const foreignUrl = `http://127.0.0.1:${foreign.port}/x.zip`;
    for (const url of [
      foreignUrl,
      `http://localhost:${library.port}/never`,
      `http://127.0.0.2:${library.port}/never`,
      `https://127.0.0.1:${library.port}/never`,
      `http://user@127.0.0.1:${library.port}/never`,
      "https://evil.invalid/x.zip",
      "ftp://github.com/x.zip",
    ]) {
      const id = publish(archive, { download_url: url });
      expect(await refused({ assetId: id })).toBe("UNTRUSTED_SOURCE");
    }
    for (const location of [
      foreignUrl,
      `http://localhost:${library.port}/never`,
    ]) {
      const id = nextId + 1;
      publish(archive, { download_url: `${origin}/redirect/${id}` });
      routes.set(
        `/redirect/${id}`,
        () =>
          new Response(null, { status: 302, headers: { Location: location } }),
      );
      expect(await refused({ assetId: id })).toBe("UNTRUSTED_SOURCE");
      expect(hits).toContain(`/redirect/${id}`);
    }
    expect(foreignHits).toEqual([]);
    expect(hits).not.toContain("/never");
  }, 60_000);

  test("more than 5 redirects give DOWNLOAD_FAILED", async () => {
    const id = publish(withAddon([]), {
      download_url: `${origin}/loop/0`,
    });
    for (let i = 0; i < 10; i++)
      routes.set(
        `/loop/${i}`,
        () =>
          new Response(null, {
            status: 302,
            headers: { Location: `/loop/${i + 1}` },
          }),
      );
    expect(await refused({ assetId: id })).toBe("DOWNLOAD_FAILED");
    expect(hits).toContain("/loop/5");
    expect(hits).not.toContain("/loop/6");
  }, 30_000);

  test("record and archive checks", async () => {
    const archive = withAddon([]);
    expect(
      await refused({ assetId: publish(archive, { type: "project" }) }),
    ).toBe("INCOMPATIBLE_ASSET");
    expect(
      await refused({ assetId: publish(archive, { godot_version: "3.5" }) }),
    ).toBe("INCOMPATIBLE_ASSET");
    expect(await refused({ assetId: publish(archive), version: "0.9.0" })).toBe(
      "VERSION_MISMATCH",
    );
    expect(
      await refused({ assetId: publish(archive), sha256: "0".repeat(64) }),
    ).toBe("HASH_MISMATCH");
    expect(
      await refused({
        assetId: publish(archive, { download_hash: "a".repeat(64) }),
      }),
    ).toBe("HASH_MISMATCH");
    expect(
      await refused({ assetId: publish(archive), sha256: "not-hex" }),
    ).toBe("INVALID_ARGUMENT");
    expect(
      await refused({
        assetId: publish(zip([{ name: "src/a.gd", data: "x" }])),
      }),
    ).toBe("INCOMPATIBLE_ASSET");
    expect(
      await refused({
        assetId: publish(
          withAddon([{ name: "addons/godot_mcp/plugin.gd", data: "x" }]),
        ),
      }),
    ).toBe("PROTECTED_PATH");
    expect(
      await refused({
        assetId: publish(
          withAddon([{ name: "addons/GODOT_MCP/plugin.gd", data: "x" }]),
        ),
      }),
    ).toBe("PROTECTED_PATH");
    expect(await refused({ assetId: 999_999 })).toBe("DOWNLOAD_FAILED");
  }, 60_000);

  test("version and sha256 pins pass when they match; an unknown hash format warns", async () => {
    const archive = zip([
      { name: "addons/pinned/a.gd", data: "extends Node\n" },
      { name: "addons/stray.txt", data: "x" },
      { name: "addons/cs/Thing.cs", data: "class Thing {}\n" },
    ]);
    const id = publish(archive, {
      download_hash: "md5:abc",
      godot_version: "4.99",
    });
    const result = await ok("install_asset", {
      assetId: id,
      version: "1.0.0",
      sha256: sha256(archive).toUpperCase(),
    });
    expect(result.addons).toEqual(["cs", "pinned"]);
    expect(result.plugins).toEqual([]);
    expect(result.needsDotnetBuild).toBe(true);
    expect(result.warnings).toHaveLength(3);
    await expect(
      lstat(join(editor.dir, "addons", "stray.txt")),
    ).rejects.toThrow();
  }, 60_000);
});

describe("install_asset as a job", () => {
  test("gives PROJECT_BUSY while run_headless runs", async () => {
    const run = ok("run_headless", { script: "res://hang.gd", timeoutSec: 3 });
    await waitFor(async () =>
      (await ok("get_project_info")).jobActive ? true : undefined,
    );
    expect(await refused({ assetId: publish(withAddon([])) })).toBe(
      "PROJECT_BUSY",
    );
    await run;
  }, 30_000);

  // A download that sends 1 KB every 100 ms of a 1 MB body.
  function slow(): number {
    const id = publish(null);
    routes.set(`/files/${id}.zip`, () => {
      let timer: ReturnType<typeof setInterval> | undefined;
      return new Response(
        new ReadableStream({
          start(controller) {
            timer = setInterval(() => {
              try {
                controller.enqueue(new Uint8Array(1024));
              } catch {
                clearInterval(timer);
              }
            }, 100);
          },
          cancel() {
            clearInterval(timer);
          },
        }),
        { headers: { "Content-Length": String(1024 * 1024) } },
      );
    });
    return id;
  }

  const jobActive = async () => (await ok("get_project_info")).jobActive;

  async function cleanAfterCancel(): Promise<void> {
    await waitFor(async () => ((await jobActive()) ? undefined : true), 10_000);
    expect(await stateDir("downloads")).toEqual([]);
    expect(await stateDir("staging")).toEqual([]);
  }

  test("other tools answer during a slow download, and a cancel returns CANCELLED and cleans up", async () => {
    const before = await tree();
    const id = slow();
    const call = fetch(`http://127.0.0.1:${editor.port}/mcp`, {
      method: "POST",
      headers: {
        Authorization: editor.auth,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 901,
        method: "tools/call",
        params: { name: "install_asset", arguments: { assetId: id } },
      }),
    }).then(async (res) => (await res.json()).result.structuredContent);
    await waitFor(() => (hits.includes(`/files/${id}.zip`) ? true : undefined));
    const started = Date.now();
    expect(await jobActive()).toBe(true);
    expect(await failure("import_assets")).toBe("PROJECT_BUSY");
    expect(Date.now() - started).toBeLessThan(2000);
    const cancel = await fetch(`http://127.0.0.1:${editor.port}/mcp`, {
      method: "POST",
      headers: {
        Authorization: editor.auth,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: { requestId: 901 },
      }),
    });
    expect(cancel.status).toBe(202);
    expect((await call).error.code).toBe("CANCELLED");
    await cleanAfterCancel();
    expect(await tree()).toEqual(before);
  }, 60_000);

  test("an SDK AbortSignal stops the download and leaves nothing behind", async () => {
    const before = await tree();
    const id = slow();
    const client = new Client({ name: "install-abort", version: "0.0.0" });
    await client.connect(
      new StreamableHTTPClientTransport(
        new URL(`http://127.0.0.1:${editor.port}/mcp`),
        { requestInit: { headers: { Authorization: editor.auth } } },
      ),
    );
    try {
      // Spend the SDK's low ids, which the harness's own calls (id 1) share.
      for (let i = 0; i < 5; i++) await client.ping();
      const controller = new AbortController();
      const call = client
        .callTool(
          { name: "install_asset", arguments: { assetId: id } },
          { signal: controller.signal, timeout: 120_000 },
        )
        .catch((error: unknown) => error);
      await waitFor(() =>
        hits.includes(`/files/${id}.zip`) ? true : undefined,
      );
      controller.abort();
      expect(await call).toBeInstanceOf(Error);
      await cleanAfterCancel();
      expect(await tree()).toEqual(before);
    } finally {
      await client.close();
    }
  }, 60_000);
});

describe("install_asset with native code", () => {
  // Loading a new .gdextension at the scan makes the editor reload every GDScript, which cancels the
  // running handler, so native code is refused even with allowNativeCode.
  test("a .gdextension or a shared library gives NATIVE_CODE, with or without allowNativeCode", async () => {
    const extension = publish(
      zip([{ name: "addons/n/n.gdextension", data: "[configuration]\n" }]),
    );
    const shared = publish(
      zip([{ name: "addons/m/bin/libm.so.1", data: "x" }]),
    );
    const framework = publish(
      zip([{ name: "addons/f/bin/f.framework/f", data: "x" }]),
    );
    for (const id of [extension, shared, framework])
      for (const allowNativeCode of [false, true])
        expect(await refused({ assetId: id, allowNativeCode })).toBe(
          "NATIVE_CODE",
        );
  }, 60_000);
});

test("the editor printed no SCRIPT ERROR", () => {
  expect(editor.output()).not.toContain("SCRIPT ERROR");
});
