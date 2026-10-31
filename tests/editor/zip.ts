import { crc32, deflateRawSync } from "node:zlib";

// A small zip writer for install_asset tests: stored and deflated entries, arbitrary (even invalid)
// names, Unix modes, flags, and declared sizes that may lie. No zip64, no data descriptors.

export interface ZipEntry {
  // A string is written as UTF-8; bytes are written as given.
  name: string | Uint8Array;
  data?: string | Uint8Array;
  // 0 stored, 8 deflated. Default 8 for files, 0 for directories (a name ending in "/").
  method?: number;
  // Unix mode, as the high 16 bits of the external attributes. Default 0o100644, or 0o40755 for a directory.
  mode?: number;
  // General purpose flags; bit 0 marks the entry encrypted.
  flags?: number;
  // The uncompressed size written in both headers, instead of the real one.
  declaredSize?: number;
}

export function zip(entries: ZipEntry[]): Uint8Array<ArrayBuffer> {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(
      typeof entry.name === "string" ? Buffer.from(entry.name) : entry.name,
    );
    const isDir = name.at(-1) === 0x2f;
    const data = Buffer.from(
      typeof entry.data === "string"
        ? Buffer.from(entry.data)
        : (entry.data ?? new Uint8Array()),
    );
    const method = entry.method ?? (isDir ? 0 : 8);
    const body = method === 8 ? deflateRawSync(data) : data;
    const size = entry.declaredSize ?? data.length;
    const mode = entry.mode ?? (isDir ? 0o40755 : 0o100644);
    const flags = entry.flags ?? 0;
    const crc = crc32(data);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt16LE(0, 10);
    local.writeUInt16LE(0x21, 12);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(size, 22);
    local.writeUInt16LE(name.length, 26);
    local.writeUInt16LE(0, 28);
    locals.push(local, name, body);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE((3 << 8) | 20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0x21, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(body.length, 20);
    central.writeUInt32LE(size, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(((mode << 16) | (isDir ? 0x10 : 0)) >>> 0, 38);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, name);
    offset += local.length + name.length + body.length;
  }
  const directory = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return new Uint8Array(Buffer.concat([...locals, directory, end]));
}
