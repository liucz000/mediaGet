#!/usr/bin/env bash
# =============================================================================
# mediaGet 自动更新脚本 —— 拉取新镜像 → 仅在 digest 变化时重建 → 健康检查失败自动回滚
#
# 手动执行：  /opt/mediaget/update.sh
# 定时执行：  crontab -e
#             0 4 * * 0  /opt/mediaget/update.sh        # 每周日 04:00
#
# 日志：      /var/log/mediaget-update.log
# =============================================================================
set -euo pipefail

DIR="${DIR:-/opt/mediaget}"
IMAGE="${IMAGE:-ghcr.io/liucz000/mediaget:latest}"
CONTAINER="${CONTAINER:-mediaget}"
LOG="${LOG:-/var/log/mediaget-update.log}"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

# 防止两次更新重叠
exec 9>/var/lock/mediaget-update.lock
flock -n 9 || { log "已有更新任务在运行，退出"; exit 0; }

cd "$DIR" || { log "目录不存在：$DIR"; exit 1; }

# 端口：优先读 .env 的 HOST_PORT，兼容 deploy.sh 生成的配置
PORT="$(sed -n 's/^HOST_PORT=\([0-9]\{1,5\}\).*/\1/p' .env 2>/dev/null | tail -1)"
[ -n "$PORT" ] || PORT="$(awk -F'"' '/published:/ {print $2; exit}' docker-compose.yml 2>/dev/null | cut -d: -f2)"
[ -n "$PORT" ] || PORT=3000

log "===== 开始检查更新 ====="

OLD_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER" 2>/dev/null || true)"
OLD_TAG="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo "$IMAGE")"
log "当前容器镜像: ${OLD_TAG} (${OLD_ID:-无})"

# 拉取新镜像（失败不中断，继续用本地缓存判断）
if ! docker compose pull --quiet; then
  log "拉取失败，继续使用本地镜像"
fi

NEW_ID="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
if [ -z "$NEW_ID" ]; then
  log "本地无可用镜像，终止"
  exit 1
fi

if [ "$OLD_ID" = "$NEW_ID" ]; then
  log "镜像无变化（$NEW_ID），无需重启"
  exit 0
fi

log "发现新镜像 $NEW_ID，重建容器"
docker compose up -d --force-recreate

# 健康检查：最多等 60s
OK=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    OK=1
    break
  fi
  sleep 2
done

if [ "$OK" = "1" ]; then
  docker image prune -f >/dev/null 2>&1 || true
  log "更新完成，健康检查通过"
  exit 0
fi

# 回滚：把旧镜像 ID 重新打回原标签并重建
log "健康检查失败，回滚到 ${OLD_ID:-上一个镜像}"
if [ -n "$OLD_ID" ]; then
  docker tag "$OLD_ID" "$OLD_TAG"
  docker compose up -d --force-recreate || true
  sleep 5
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    log "回滚成功，服务已恢复"
  else
    log "回滚后仍不健康，请人工介入：docker logs $CONTAINER"
  fi
else
  log "无旧镜像可回滚，请人工介入"
fi
exit 1
