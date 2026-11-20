'use strict';
// Consistent copy of one SQLite database into /dumps (#195), the SQLite
// counterpart of db-dump/dump.bash. Runs on the pinned Pangolin image, which
// ships Node and better-sqlite3 (NODE_PATH=/app/node_modules).
//
//   node /dump.cjs dump <name> <source db>
//     <name>.sqlite  VACUUM INTO copy: one statement, one read transaction,
//                    so a consistent snapshot while the app keeps writing.
//                    The source is opened read-only; SQLite may still touch
//                    its -shm/-wal.
//     <name>.counts  "<table>\t<rows>", user tables, byte-sorted
//     <name>.done    written last: UTC time, then "sha256  <file>" for the
//                    .sqlite and .counts, so a restore can tell a set whose
//                    files were read mid-replacement (restic at 00:00)
//   node /dump.cjs check <copy> <counts>
//     exit 0 only if integrity_check is ok and the copy's counts equal the
//     file's exactly.
//
// Everything is written as .tmp and renamed; .done is removed before the
// first rename, so a run killed between renames leaves no .done (#199).
// Exit 1 on any failure, 2 on bad usage.
const fs = require('fs');
const crypto = require('crypto');
const Database = require('better-sqlite3');

function fail(msg) {
  process.stderr.write(msg + '\n');
  process.exit(1);
}

function tables(db) {
  return db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
    .all()
    .map((r) => r.name);
}

// "<table>\t<rows>" lines, sorted by bytes (LC_ALL=C sort order).
function counts(db) {
  return tables(db)
    .map((t) => `${t}\t${db.prepare(`SELECT count(*) AS n FROM "${t.replaceAll('"', '""')}"`).get().n}`)
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
}

function integrity(db) {
  const rows = db.pragma('integrity_check');
  if (!(rows.length === 1 && rows[0].integrity_check === 'ok')) {
    throw new Error(rows.map((r) => r.integrity_check).slice(0, 3).join('; '));
  }
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function dump(name, src) {
  const dir = '/dumps';
  const out = `${dir}/${name}`;
  process.umask(0o077);
  fs.chmodSync(dir, 0o700);
  // A killed run can't clean up after itself; the next one does.
  for (const f of fs.readdirSync(dir)) {
    if (f.startsWith(`${name}.`) && f.endsWith('.tmp')) fs.rmSync(`${dir}/${f}`, { force: true });
  }
  if (!fs.existsSync(src)) fail(`no database at ${src}`);

  try {
    const source = new Database(src, { readonly: true, fileMustExist: true });
    source.pragma('busy_timeout = 30000');
    source.exec(`VACUUM INTO '${`${out}.sqlite.tmp`.replaceAll("'", "''")}'`);
    source.close();

    const copy = new Database(`${out}.sqlite.tmp`, { readonly: true, fileMustExist: true });
    integrity(copy);
    const lines = counts(copy);
    copy.close();
    fs.writeFileSync(`${out}.counts.tmp`, lines.map((l) => l + '\n').join(''));

    fs.rmSync(`${out}.done`, { force: true });
    fs.renameSync(`${out}.sqlite.tmp`, `${out}.sqlite`);
    fs.renameSync(`${out}.counts.tmp`, `${out}.counts`);
    const stamp = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    fs.writeFileSync(
      `${out}.done.tmp`,
      `${stamp}\n${sha256(`${out}.sqlite`)}  ${name}.sqlite\n${sha256(`${out}.counts`)}  ${name}.counts\n`,
    );
    fs.renameSync(`${out}.done.tmp`, `${out}.done`);
    console.log(`dumped ${name}: ${fs.statSync(`${out}.sqlite`).size} bytes, ${lines.length} tables`);
  } catch (e) {
    fail(`${name}: ${e.message}`);
  }
}

function check(copyPath, countsPath) {
  let got;
  try {
    const db = new Database(copyPath, { readonly: true, fileMustExist: true });
    integrity(db);
    got = counts(db);
    db.close();
  } catch (e) {
    fail(`integrity_check failed: ${e.message}`);
  }
  const want = fs.readFileSync(countsPath, 'utf8').split('\n').filter(Boolean);
  const g = new Map(got.map((l) => l.split('\t')));
  const w = new Map(want.map((l) => l.split('\t')));
  for (const t of new Set([...g.keys(), ...w.keys()])) {
    if (g.get(t) !== w.get(t)) fail(`counts differ: ${t} (copy ${g.get(t) ?? 'missing'}, file ${w.get(t) ?? 'missing'})`);
  }
  console.log(`ok ${got.length} tables`);
}

const [mode, a, b] = process.argv.slice(2);
if (mode === 'dump' && a && b) dump(a, b);
else if (mode === 'check' && a && b) check(a, b);
else {
  process.stderr.write('usage: dump.cjs dump <name> <source db> | check <copy> <counts>\n');
  process.exit(2);
}
