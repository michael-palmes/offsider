#!/bin/bash
# Rebuilds the SQLite fixtures beside this script with the Mac's own sqlite3. Every value holds the canary, which no test may ever see leave a database.
# Usage: Tests/Fixtures/sqlite/make-fixtures.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sqlite=/usr/bin/sqlite3
canary="OFFSIDER-CANARY-VALUE-5e1d7c"
legacy="CREATE TABLE android_metadata (locale TEXT); CREATE TABLE catalystLocalStorage (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
room='CREATE TABLE android_metadata (locale TEXT); CREATE TABLE `Storage` (`key` TEXT NOT NULL, `value` TEXT, PRIMARY KEY(`key`)); CREATE TABLE room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT);'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Rows named <prefix>-0001 and up, each value a few canaries long.
rows() {
    local table="$1" prefix="$2" count="$3" repeat="${4:-2}"
    echo "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < $count) INSERT INTO $table SELECT printf('$prefix-%04d', i), replace(hex(zeroblob($repeat)), '00', '$canary ') FROM n;"
}

# The pages of the key index, which is all a reader may ask for beyond page 1.
pages() {
    local database="$1" table="$2"
    "$sqlite" "$database" "SELECT group_concat(pageno, ' ') FROM (SELECT pageno FROM dbstat WHERE name = 'sqlite_autoindex_${table}_1' AND pagetype IN ('leaf', 'internal') ORDER BY pageno);" > "$here/$(basename "$database").pages"
}

build() {
    local name="$1" table="$2"
    rm -f "$here/$name" "$here/$name-wal" "$here/$name.pages"
    "$sqlite" "$here/$name" > /dev/null
    if [ -n "$table" ]; then pages "$here/$name" "$table"; fi
}

build legacy.db catalystLocalStorage <<SQL
PRAGMA auto_vacuum = 1;
$legacy
INSERT INTO catalystLocalStorage VALUES ('offsider-fixture-theme', '$canary dark'), ('offsider-fixture-profile', '{"plan":"$canary"}'), ('session:person@example.com', '$canary'), ('', '$canary');
SQL

build room.db Storage <<SQL
PRAGMA auto_vacuum = 1;
$room
INSERT INTO Storage VALUES ('offsider-fixture-theme', '$canary dark'), ('offsider-fixture-profile', NULL), ('third', '$canary');
SQL

build two-level.db catalystLocalStorage <<SQL
PRAGMA auto_vacuum = 1;
$legacy
$(rows catalystLocalStorage offsider-fixture-key 300 1)
SQL

build deep.db catalystLocalStorage <<SQL
PRAGMA page_size = 512;
PRAGMA auto_vacuum = 1;
$legacy
$(rows catalystLocalStorage offsider-fixture-key 1000 1)
SQL

build overflow.db catalystLocalStorage <<SQL
PRAGMA page_size = 1024;
$legacy
INSERT INTO catalystLocalStorage VALUES ('short', '$canary'), ('long-' || replace(hex(zeroblob(1500)), '00', 'k'), '$canary');
SQL

# The deleted row's value is still in the table page's free space.
build empty.db catalystLocalStorage <<SQL
PRAGMA secure_delete = OFF;
$legacy
INSERT INTO catalystLocalStorage VALUES ('gone', '$canary');
DELETE FROM catalystLocalStorage;
SQL

build utf16.db "" <<SQL
PRAGMA encoding = 'UTF-16le';
$legacy
INSERT INTO catalystLocalStorage VALUES ('offsider-fixture-theme', '$canary');
SQL

build without-rowid.db "" <<SQL
CREATE TABLE catalystLocalStorage (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
INSERT INTO catalystLocalStorage VALUES ('offsider-fixture-theme', '$canary');
SQL

# The first automatic index here is on the value, so a reader that trusted the index's name alone would list values.
build value-first.db "" <<SQL
CREATE TABLE catalystLocalStorage (value TEXT UNIQUE, key TEXT PRIMARY KEY);
INSERT INTO catalystLocalStorage VALUES ('$canary', 'offsider-fixture-theme');
SQL

# A second index, here on the value, has pages the device cannot tell from the key index's.
build value-index.db "" <<SQL
$legacy
CREATE INDEX by_value ON catalystLocalStorage (value);
INSERT INTO catalystLocalStorage VALUES ('offsider-fixture-theme', '$canary');
SQL

# So has a WITHOUT ROWID table beside the right one: its index pages hold whole rows.
build rowless-neighbour.db "" <<SQL
$legacy
CREATE TABLE cache (name TEXT PRIMARY KEY, secret TEXT) WITHOUT ROWID;
INSERT INTO catalystLocalStorage VALUES ('offsider-fixture-theme', '$canary');
INSERT INTO cache VALUES ('entry', '$canary');
SQL

# With secure_delete off, an index that grows into pages table rows left in the same transaction keeps their values in its free space.
build reused.db catalystLocalStorage <<SQL
PRAGMA secure_delete = OFF;
$legacy
$(rows catalystLocalStorage old 40 30)
BEGIN;
DELETE FROM catalystLocalStorage;
$(rows catalystLocalStorage offsider-fixture-key 300 1)
COMMIT;
SQL

# A log holding committed frames, then a transaction cut off before its commit frame, as a crash mid-commit leaves it.
rm -f "$here/wal.db" "$here/wal.db-wal" "$here/wal.db.pages"
"$sqlite" "$work/wal.db" > /dev/null <<SQL
PRAGMA auto_vacuum = 1;
PRAGMA journal_mode = WAL;
PRAGMA wal_autocheckpoint = 0;
$room
INSERT INTO Storage VALUES ('checkpointed', '$canary');
PRAGMA wal_checkpoint(TRUNCATE);
INSERT INTO Storage VALUES ('offsider-fixture-theme', '$canary dark'), ('offsider-fixture-profile', '$canary');
$(rows Storage committed 60)
.shell cp "$work/wal.db" "$work/committed.db" && cp "$work/wal.db-wal" "$work/committed.db-wal"
$(rows Storage uncommitted 40)
.shell cp "$work/wal.db" "$here/wal.db" && cp "$work/wal.db-wal" "$work/whole-wal"
SQL
head -c $(($(wc -c < "$work/whole-wal") - 4096 - 24)) "$work/whole-wal" > "$here/wal.db-wal"
pages "$work/committed.db" Storage
mv "$here/committed.db.pages" "$here/wal.db.pages"

# A log that restarted after a checkpoint: its first frames are new, and the old ones behind them carry the last log's salts.
rm -f "$here/wal-restarted.db" "$here/wal-restarted.db-wal" "$here/wal-restarted.db.pages"
"$sqlite" "$work/restarted.db" > /dev/null <<SQL
PRAGMA auto_vacuum = 1;
PRAGMA journal_mode = WAL;
PRAGMA wal_autocheckpoint = 0;
$room
$(rows Storage kept 80)
INSERT INTO Storage VALUES ('removed-after-restart', '$canary');
PRAGMA wal_checkpoint(RESTART);
DELETE FROM Storage WHERE key = 'removed-after-restart';
.shell cp "$work/restarted.db" "$here/wal-restarted.db" && cp "$work/restarted.db-wal" "$here/wal-restarted.db-wal"
SQL
pages "$work/restarted.db" Storage
mv "$here/restarted.db.pages" "$here/wal-restarted.db.pages"

# The fuzz target starts from whole databases.
seeds="$here/../fuzz/sqlite-key-index"
mkdir -p "$seeds"
cp "$here/legacy.db" "$here/room.db" "$here/overflow.db" "$here/value-first.db" "$seeds/"

ls -l "$here"
