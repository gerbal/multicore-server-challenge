#!/usr/bin/env bash
# Checks the server binds 0.0.0.0:80 the way the box's systemd unit runs it: as an unprivileged user holding only
# the ambient CAP_NET_BIND_SERVICE (box/challenge.service), and that it fails without the capability.
#
#   sudo tuning/port80.sh        (root: creates a `challenge` user, copies the built submission to its home)
#
# Port 80 must be free. Needs setpriv (util-linux).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/.." && pwd)
TEMPLATE=${TEMPLATE:-conduit_dev}
export PGHOST=${PGHOST:-127.0.0.1} PGUSER=${PGUSER:-postgres}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -x "$SRC/_build/prod/rel/conduit/bin/conduit" ] || { echo "build the release first"; exit 1; }

id challenge >/dev/null 2>&1 || useradd -m challenge
rm -rf /home/challenge/app && cp -r "$SRC" /home/challenge/app && chown -R challenge:challenge /home/challenge/app
psql -X -q -d postgres -c "DROP DATABASE IF EXISTS conduit_p80 WITH (FORCE)" \
  -c "CREATE DATABASE conduit_p80 TEMPLATE $TEMPLATE STRATEGY FILE_COPY" || exit 1
ENVS=(DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_p80 JWT_SECRET=x HOST=0.0.0.0 PORT=80
      HOME=/home/challenge PATH=/usr/local/bin:/usr/bin:/bin)
stop() { pkill -u challenge -f "[b]eam.smp"; sleep 1; }

echo "== without the capability (expect no answer and an eacces bind error)"
setpriv --reuid challenge --regid challenge --init-groups env -i "${ENVS[@]}" \
  bash /home/challenge/app/start.sh > /tmp/port80-nocap.log 2>&1 &
sleep 8
curl -s -m 2 -o /dev/null -w "GET :80 -> %{http_code}\n" http://127.0.0.1:80/api/tags || true
grep -m1 -o "eacces" /tmp/port80-nocap.log || echo "(no eacces in log; see /tmp/port80-nocap.log)"
stop

echo "== with ambient CAP_NET_BIND_SERVICE only (expect 200)"
setpriv --reuid challenge --regid challenge --init-groups --inh-caps +net_bind_service \
  --ambient-caps +net_bind_service env -i "${ENVS[@]}" bash /home/challenge/app/start.sh > /tmp/port80-cap.log 2>&1 &
for _ in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:80/api/tags && break; sleep 0.5; done
curl -s -o /dev/null -w "GET :80 -> %{http_code}\n" http://127.0.0.1:80/api/tags
echo "beam runs as: $(ps -o user= -p "$(pgrep -u challenge -f '[b]eam.smp' | head -1)")"
echo "listen backlog (Send-Q; capped by net.core.somaxconn=$(sysctl -n net.core.somaxconn)): $(ss -Hltn 'sport = :80' | awk '{print $3}')"
stop
psql -X -q -d postgres -c "DROP DATABASE IF EXISTS conduit_p80 WITH (FORCE)"
