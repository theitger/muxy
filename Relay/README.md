# Muxy relay

Lets the phone reach Muxy from any network: Muxy connects out to the relay,
the phone connects to it too, the relay passes frames between them. The
frames are end-to-end encrypted (`Sources/muxy/Remote/RemoteCrypto.swift`),
so the relay can neither read nor forge them, and it stores nothing. The
same host serves the phone app over HTTPS.

What the relay does see: which IPs connect, when, and how much traffic.

## Setup (once)

On a server with nginx and certbot (Ubuntu here):

1. DNS: `A`/`AAAA` for e.g. `muxy.example.com` → the server.
2. Muxy's room id — only that Mac may register. On the Mac:
   ```sh
   python3 -c "import hashlib,os;t=open(os.path.expanduser('~/Library/Application Support/Muxy/remote-relay-token'),'rb').read();print(hashlib.sha256(b'muxy-room'+t).hexdigest()[:32])"
   ```
   (The token is created by Muxy the first time a relay is set in
   Settings → Phone; or create it: `openssl rand 32 > …/remote-relay-token`.)
3. On the server:
   ```sh
   echo 'MUXY_RELAY_ROOMS=<room id>' > /etc/muxy-relay.env   # comma-separate several Macs
   cp deploy/muxy-relay.service /etc/systemd/system/
   mkdir -p /var/www/muxy.example.com
   sed 's/muxy.example.com/<your host>/g' deploy/nginx.conf > /etc/nginx/sites-available/<your host>
   ln -s /etc/nginx/sites-available/<your host> /etc/nginx/sites-enabled/
   nginx -t && systemctl reload nginx
   certbot --nginx -d <your host> --redirect
   ```
4. From the Mac: `deploy/deploy.sh root@<server> <your host>` — builds and
   installs the relay binary and the phone app, (re)starts the service.
5. Muxy → Settings → Phone: enter the host as relay, switch on, scan.

No extra firewall ports: everything goes through nginx on 443. The service
runs as a throwaway user with the system locked down
(`systemd-analyze security muxy-relay`).

## Updating

`deploy/deploy.sh root@<server> <your host>`
