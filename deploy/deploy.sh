#!/usr/bin/env bash
# =============================================================================
# mediaGet 一键部署脚本 —— 在目标服务器上以 root 运行
#
#   bash deploy.sh --domain jx.lcz.ccwu.cc
#   bash deploy.sh --domain jx.lcz.ccwu.cc --no-caddy     # 不用 Caddy，直接暴露端口
#
# 做的事：装 Docker → 生成 .env / docker-compose.yml → 拉 GHCR 镜像 → 启动
#         → (可选) 装 Caddy 配 HTTPS → 健康检查
# 幂等：重复执行只会拉新镜像并重建容器，不动已存在的 .env
# =============================================================================
set -euo pipefail

DOMAIN=""
PORT="3000"
IMAGE="ghcr.io/liucz000/mediaget:latest"
DIR="/opt/mediaget"
USE_CADDY=1
EMAIL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port)   PORT="$2"; shift 2 ;;
    --image)  IMAGE="$2"; shift 2 ;;
    --dir)    DIR="$2"; shift 2 ;;
    --email)  EMAIL="$2"; shift 2 ;;
    --no-caddy) USE_CADDY=0; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请以 root 运行"
[ "$(uname -m)" = "x86_64" ] || die "镜像仅支持 linux/amd64，当前为 $(uname -m)"

if [ -n "$DOMAIN" ]; then
  SITE_URL="https://$DOMAIN"
else
  SITE_URL="http://127.0.0.1:$PORT"
fi

# ---------- 1. Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  log "安装 Docker"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  log "Docker 已就绪：$(docker --version)"
fi
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件（请安装 docker-compose-plugin）"

# ---------- 2. 目录与配置 ----------
mkdir -p "$DIR" && cd "$DIR"

if [ ! -f .env ]; then
  log "生成 .env（后续请编辑此文件填入 BILIBILI_COOKIE 等）"
  umask 077
  cat > .env <<EOF
VIDEO_PARSE_ENABLED=true
NEXT_PUBLIC_SITE_URL=$SITE_URL
EOF
else
  log ".env 已存在，保留不覆盖"
fi

# 是否把端口只绑本机（由 Caddy 反代）
BIND_ADDR="0.0.0.0"
if [ "$USE_CADDY" = 1 ] && [ -n "$DOMAIN" ]; then BIND_ADDR="127.0.0.1"; fi

log "写入 docker-compose.yml"
cat > docker-compose.yml <<EOF
services:
  mediaget:
    image: $IMAGE
    container_name: mediaget
    restart: unless-stopped
    ports:
      - "$BIND_ADDR:$PORT:3000"
    env_file: .env
    environment:
      NODE_ENV: production
      NODE_OPTIONS: --max-old-space-size=768
    mem_limit: 1g
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

# ---------- 3. 拉镜像并启动 ----------
log "拉取镜像 $IMAGE"
docker pull "$IMAGE"
log "启动容器"
docker compose up -d --force-recreate
docker compose ps

# ---------- 4. 健康检查 ----------
log "等待服务就绪"
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    log "健康检查通过：$(curl -fsS "http://127.0.0.1:$PORT/api/health")"
    break
  fi
  [ "$i" -eq 30 ] && { warn "30 次探测未通过，请查看日志：docker logs mediaget"; }
  sleep 2
done

# ---------- 5. 可选：Caddy HTTPS ----------
if [ "$USE_CADDY" = 1 ] && [ -n "$DOMAIN" ]; then
  CADDY_OK=1
  if ! command -v caddy >/dev/null 2>&1; then
    log "安装 Caddy"
    CADDY_OK=0
    if command -v apt-get >/dev/null 2>&1; then
      . /etc/os-release
      case "${ID:-}" in
        debian|ubuntu)
          apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null 2>&1 || true
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
          curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
          apt-get update -qq >/dev/null 2>&1 || true
          apt-get install -y -qq caddy >/dev/null 2>&1 || true
          command -v caddy >/dev/null 2>&1 && CADDY_OK=1
          ;;
      esac
    fi
  fi

  if [ "$CADDY_OK" = 1 ]; then
    log "配置 Caddy 反向代理 $DOMAIN → 127.0.0.1:$PORT"
    mkdir -p /etc/caddy
    if [ -n "$EMAIL" ]; then
      cat > /etc/caddy/Caddyfile <<EOF
{
	email $EMAIL
}

$DOMAIN {
	reverse_proxy 127.0.0.1:$PORT
}
EOF
    else
      cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
	reverse_proxy 127.0.0.1:$PORT
}
EOF
    fi
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
  else
    warn "Caddy 安装失败（非 Debian/Ubuntu 或无网络），改为直接暴露 $PORT 端口"
    sed -i "s|127.0.0.1:$PORT:3000|0.0.0.0:$PORT:3000|" docker-compose.yml
    docker compose up -d --force-recreate >/dev/null
  fi
fi

# ---------- 6. 防火墙 ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  [ "$BIND_ADDR" = "0.0.0.0" ] && { ufw allow "$PORT"/tcp >/dev/null 2>&1 || true; }
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
  [ "$BIND_ADDR" = "0.0.0.0" ] && { firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 || true; }
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

# ---------- 7. DNS 提示 ----------
if [ -n "$DOMAIN" ]; then
  RESOLVED=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)
  SERVER_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  if [ -n "$RESOLVED" ] && [ -n "$SERVER_IP" ] && [ "$RESOLVED" != "$SERVER_IP" ]; then
    warn "DNS 不一致：$DOMAIN → ${RESOLVED}，本机公网 IP 为 $SERVER_IP；HTTPS 可能签发失败"
  fi
fi

cat <<EOF

=============================================================================
 部署完成
-----------------------------------------------------------------------------
 访问地址 : ${DOMAIN:+https://$DOMAIN}${DOMAIN:-http://<服务器IP>:$PORT}
 本地探测 : http://127.0.0.1:$PORT/api/health
 配置目录 : $DIR/.env   （填入 BILIBILI_COOKIE 等后执行：）
            cd $DIR && docker compose up -d --force-recreate
 查看日志 : docker logs -f mediaget
 更新版本 : cd $DIR && docker compose pull && docker compose up -d
 健康状态 : docker inspect --format '{{.State.Health.Status}}' mediaget
-----------------------------------------------------------------------------
 务必确认云厂商安全组已放行 80/443（${BIND_ADDR} 模式无需放行 $PORT）
=============================================================================
EOF
