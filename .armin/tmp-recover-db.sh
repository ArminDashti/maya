#!/bin/sh
set -eu
cd /data
ls -la
/usr/bin/sqlite3 -version
/usr/bin/sqlite3 webui.db <<'SQL' > webui.recover.sql
.recover
SQL
echo "recover_bytes=$(wc -c < webui.recover.sql)"
head -n 5 webui.recover.sql
rm -f webui.db.recovered
/usr/bin/sqlite3 webui.db.recovered < webui.recover.sql
echo -n "integrity="
/usr/bin/sqlite3 webui.db.recovered "PRAGMA integrity_check;"
echo -n "chats="
/usr/bin/sqlite3 webui.db.recovered "SELECT count(*) FROM chat;"
echo -n "models="
/usr/bin/sqlite3 webui.db.recovered "SELECT count(*) FROM model;"
echo "active models:"
/usr/bin/sqlite3 webui.db.recovered "SELECT id, name, base_model_id FROM model WHERE is_active=1;"
ok=$(/usr/bin/sqlite3 webui.db.recovered "PRAGMA integrity_check;")
if [ "$ok" = "ok" ]; then
  cp -f webui.db webui.db.pre-swap
  mv -f webui.db.recovered webui.db
  rm -f webui.db-wal webui.db-shm
  echo "SWAPPED_OK"
else
  echo "SWAPPED_SKIP integrity=$ok"
  exit 2
fi
