#!/bin/bash
# EC2 boot script (Amazon Linux 2023). launch.sh fills in the __PLACEHOLDERS__.
# Builds the API image from the repo's Dockerfile on the instance itself and
# serves it over HTTPS through Caddy (automatic Let's Encrypt certificate).
set -euxo pipefail
exec > >(tee -a /var/log/jit-setup.log) 2>&1

REPO_URL="__REPO_URL__"
HOST="__HOST__"
API_KEY="__API_KEY__"

# 1 GB swap: t3.micro has 1 GB RAM and pip install inside docker build needs headroom.
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

dnf install -y docker git
systemctl enable --now docker

mkdir -p /opt/jit
umask 077
printf 'API_KEY=%s\n' "$API_KEY" > /opt/jit/api.env
umask 022

if [ ! -d /opt/jit/repo/.git ]; then
  git clone --depth 1 "$REPO_URL" /opt/jit/repo
fi

cat > /opt/jit/Caddyfile <<EOF
$HOST {
    encode gzip
    reverse_proxy api:8000
}
EOF

cat > /opt/jit/redeploy.sh <<'EOF'
#!/bin/bash
# Pull the latest main, rebuild the image and restart the API container.
set -euo pipefail
cd /opt/jit/repo
git fetch --depth 1 origin main
git reset --hard origin/main
docker build -t jit-api .
docker rm -f api 2>/dev/null || true
docker run -d --name api --network jit --restart always --env-file /opt/jit/api.env jit-api
docker image prune -f
echo "Redeployed $(git rev-parse --short HEAD)"
EOF
chmod +x /opt/jit/redeploy.sh

docker network inspect jit >/dev/null 2>&1 || docker network create jit

/opt/jit/redeploy.sh

docker rm -f caddy 2>/dev/null || true
docker run -d --name caddy --network jit --restart always \
  -p 80:80 -p 443:443 \
  -v /opt/jit/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v caddy_data:/data -v caddy_config:/config \
  caddy:2

echo "Setup finished: https://$HOST/health"
