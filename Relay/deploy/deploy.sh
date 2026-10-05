#!/usr/bin/env bash
# Updates the relay binary and the phone app on an existing relay host
# (first-time setup: README.md). Usage: deploy/deploy.sh root@host muxy.example.com
set -euo pipefail
HOST="$1"
NAME="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

(cd "$HERE" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o dist/muxy-relay .)
(cd "$REPO/Prototypes/remote" && pnpm install --frozen-lockfile --silent && pnpm build >/dev/null)

scp -q "$HERE/dist/muxy-relay" "$HOST:/usr/local/bin/muxy-relay.new"
scp -q "$REPO/Prototypes/remote/dist/index.html" "$HOST:/var/www/$NAME/index.html.new"
ssh "$HOST" "set -e
install -m 755 /usr/local/bin/muxy-relay.new /usr/local/bin/muxy-relay && rm /usr/local/bin/muxy-relay.new
mv /var/www/$NAME/index.html.new /var/www/$NAME/index.html && chmod 644 /var/www/$NAME/index.html
systemctl restart muxy-relay && systemctl is-active muxy-relay"
echo "deployed to $NAME"
