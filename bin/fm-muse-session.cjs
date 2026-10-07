// Decode Muse's durable session records, including 1.4.0 permission frames.
// Usage: node fm-muse-session.cjs matching <sessions-root> <workspace>
//        node fm-muse-session.cjs events <session.jsonl>
// Only complete JSONL records are visible. An append still in progress is not
// a terminal, and JSON embedded in arbitrary payload text is never a record.
// The log is append-only, so a complete line that does not decode, such as a
// torn append a later resume wrote onto, is skipped rather than poisoning
// every later read of that session.
const fs = require("fs");
const path = require("path");

function decode(line) {
  try {
    const record = JSON.parse(line);
    if (record.retained_frame === "session_permission_transaction" && record.frame_schema_version === 1) {
      return record.children.map((child) => JSON.parse(child.record_json));
    }
    return [record];
  } catch {
    return [];
  }
}

function* records(file, maxBytes = Infinity) {
  const fd = fs.openSync(file, "r");
  try {
    const buffer = Buffer.alloc(65536);
    let pending = Buffer.alloc(0);
    let total = 0;
    while (total < maxBytes) {
      const n = fs.readSync(fd, buffer, 0, Math.min(buffer.length, maxBytes - total), null);
      if (!n) break;
      total += n;
      pending = Buffer.concat([pending, buffer.subarray(0, n)]);
      let start = 0;
      let end;
      while ((end = pending.indexOf(10, start)) !== -1) {
        const line = pending.subarray(start, end).toString("utf8");
        start = end + 1;
        if (!line.trim()) continue;
        yield* decode(line);
      }
      pending = pending.subarray(start);
    }
  } finally {
    fs.closeSync(fd);
  }
}

function metadataWorkspace(file) {
  // Metadata is in the startup prefix, after the permission transaction in
  // 1.4.0. Bound discovery without reading a growing multi-turn transcript.
  for (const record of records(file, 1024 * 1024)) {
    if (record.payload_type === "runtime.session.metadata" && record.payload?.kind === "metadata") {
      return record.payload.record?.workspace_root;
    }
  }
}

function directories(parent) {
  try {
    return fs.readdirSync(parent, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(parent, entry.name));
  } catch {
    return [];
  }
}

function matching(root, workspace) {
  // Exactly YYYY/MM/DD/session: never a native child or reminder transcript.
  for (const year of directories(root)) {
    for (const month of directories(year)) {
      for (const day of directories(month)) {
        for (const session of directories(day)) {
          const file = path.join(session, "session.jsonl");
          try {
            if (fs.lstatSync(file).isFile() && metadataWorkspace(file) === workspace) {
              process.stdout.write(`${file}\n`);
            }
          } catch { /* An incomplete or unreadable binding is not a match. */ }
        }
      }
    }
  }
}

function events(file) {
  const result = [];
  for (const record of records(file)) {
    const p = record.payload;
    if (record.payload_type !== "runtime.session" || p?.kind !== "run") continue;
    const event = p.event;
    if (!["started", "terminal"].includes(event?.kind)) continue;
    if (typeof p.run_id !== "string" || !p.run_id || /[\t\r\n]/.test(p.run_id)) throw new Error("invalid run id");
    // The run id is what pairs a close with its start; the terminal reason is
    // only detail. An unexpected reason still closes the run, as it did in the
    // byte fold, rather than failing every later read of an append-only log.
    let terminal = event.kind === "terminal" ? event.terminal : "";
    if (typeof terminal !== "string" || /[\t\r\n]/.test(terminal)) terminal = "";
    result.push(`${p.run_id}\t${event.kind}\t${terminal}\n`);
  }
  // Do not publish a partial fold if a run record was invalid.
  process.stdout.write(result.join(""));
}

try {
  const [mode, first, second] = process.argv.slice(2);
  if (mode === "matching") matching(first, second);
  else if (mode === "events") events(first);
  else process.exitCode = 1;
} catch {
  process.exitCode = 1;
}
