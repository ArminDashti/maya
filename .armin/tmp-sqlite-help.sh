#!/bin/sh
set -eu
/usr/bin/sqlite3 <<'EOF'
.help recover
.help
EOF
