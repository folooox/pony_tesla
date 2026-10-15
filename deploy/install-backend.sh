#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(id -u)" != 0 ]; then
    echo 'Run as root on the deployment server.' >&2
    exit 1
fi
if ! id pony-tesla >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /opt/pony-tesla --shell /usr/sbin/nologin pony-tesla
fi
install -d -m 0755 /opt/pony-tesla /opt/pony-tesla/bin /opt/pony-tesla/backend
install -d -m 0700 -o pony-tesla -g pony-tesla /opt/pony-tesla/.private
if [ -f /opt/pony-tesla/.private/public-key.pem ]; then
    cmp --silent .private/public-key.pem /opt/pony-tesla/.private/public-key.pem || {
        echo 'Existing deployment uses another public key; stopped without replacing it.' >&2
        exit 1
    }
fi
if ! cmp --silent "$(command -v node)" /opt/pony-tesla/bin/node; then
    install -m 0755 "$(command -v node)" /opt/pony-tesla/bin/node.next
    mv /opt/pony-tesla/bin/node.next /opt/pony-tesla/bin/node
fi
cp -R backend/. /opt/pony-tesla/backend/
chmod -R a+rX /opt/pony-tesla/backend
for file in public-key.pem private-key.pem; do
    if [ ! -f "/opt/pony-tesla/.private/$file" ]; then
        install -m 0600 -o pony-tesla -g pony-tesla ".private/$file" "/opt/pony-tesla/.private/$file"
    fi
done
if [ -f .private/registration.json ]; then
    install -m 0600 -o pony-tesla -g pony-tesla .private/registration.json /opt/pony-tesla/.private/registration.json
fi
# Tokens are owned by the live deployment; never replace them with stale test tokens.
python3 - <<'PY'
from pathlib import Path
import os
source = Path('.env').read_text().splitlines()
updates = {'PUBLIC_ORIGIN': 'https://tesla.ponypro.party', 'LISTEN_HOST': '172.20.0.1'}
rows = [line for line in source if line.partition('=')[0] not in updates]
rows += [f'{key}={value}' for key, value in updates.items()]
# Preserve configured outbound proxy/CA environment without displaying credentials.
for key in ['HTTP_PROXY','HTTPS_PROXY','NO_PROXY','http_proxy','https_proxy','no_proxy','NODE_EXTRA_CA_CERTS']:
    if key in os.environ and not any(line.startswith(key+'=') for line in rows):
        value = os.environ[key]
        if any(c in value for c in ['\n','\r','"','\\']):
            raise SystemExit('Proxy environment requires explicit systemd-compatible configuration')
        rows.append(f'{key}="{value}"')
path = Path('/opt/pony-tesla/.env')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as stream:
    stream.write('\n'.join(rows)+'\n')
os.chmod(path, 0o600)
PY
install -m 0644 deploy/pony-tesla.service /etc/systemd/system/pony-tesla.service
systemctl daemon-reload
systemctl enable pony-tesla.service
systemctl restart pony-tesla.service
systemctl is-active pony-tesla.service
