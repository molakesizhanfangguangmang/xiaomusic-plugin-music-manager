#!/usr/bin/env bash
# =============================================================================
# unpatch_music_manager.sh — 回滚「歌曲管理」后端补丁
#
# 把容器里的四个文件还原：
#   /app/xiaomusic/music_library.py
#   /app/xiaomusic/api/routers/music.py
#   /app/xiaomusic/device_player.py
#   /app/xiaomusic/xiaomusic.py
#
# 还原来源优先级：
#   1) 本目录下最近的 *.bak_<时间戳> 备份（patch_music_manager.sh 留下的）
#   2) 没有备份时，从镜像原版恢复（docker run --rm 同镜像 cat 出来）
#
# 【注意】还原会一并丢掉 duration-refresh 插件的改动（共用同一批文件）——
#   本补丁的基线含 duration-refresh，回滚等于退回到打本补丁之前的状态。
#   若还要用 duration-refresh，回滚后需重打它的 patch_duration.sh。
#
# 幂等：重复执行结果一致。执行前同样会先备份当前文件。
#
# 用法：
#   ./unpatch_music_manager.sh                 # 默认容器名 xiaomusic
#   ./unpatch_music_manager.sh -c myxiaomusic
#   ./unpatch_music_manager.sh --dry-run
#   ./unpatch_music_manager.sh -f              # 跳过确认
# =============================================================================

set -u

readonly CONT_APP='/app/xiaomusic'
readonly CONT_MUSIC_LIB="$CONT_APP/music_library.py"
readonly CONT_MUSIC_ROUTER="$CONT_APP/api/routers/music.py"
readonly CONT_DEVICE_PLAYER="$CONT_APP/device_player.py"
readonly CONT_XIAOMUSIC="$CONT_APP/xiaomusic.py"

readonly PKG_DIR="$(cd "$(dirname "$0")" && pwd)"

CONTAINER="${CONTAINER:-xiaomusic}"
DRY_RUN=0
FORCE=0

info() { printf '\033[0;36m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--container) CONTAINER="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -f|--force)     FORCE=1; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { err "找不到 docker 命令"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || {
  err "找不到运行中的容器「$CONTAINER」；用 -c <名> 指定"; exit 1; }

# --- 找最近的备份 -------------------------------------------------------------
find_backup() {
  # $1 = 文件名（如 music_library.py）
  ls -1 "$PKG_DIR/$1".bak_* 2>/dev/null | sort | tail -n 1
}

declare -a PAIRS=(
  "$CONT_MUSIC_LIB:music_library.py"
  "$CONT_MUSIC_ROUTER:music.py"
  "$CONT_DEVICE_PLAYER:device_player.py"
  "$CONT_XIAOMUSIC:xiaomusic.py"
)

echo
info "将还原以下文件到容器「$CONTAINER」："
srcs=()
for pair in "${PAIRS[@]}"; do
  name="${pair##*:}"
  b="$(find_backup "$name")"
  if [ -n "$b" ]; then
    echo "    $name  <- 备份 $b"
    srcs+=("$b")
  else
    echo "    $name  <- 镜像原版（无备份）"
    srcs+=("")
  fi
done
echo

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] 未做任何写入。"
  exit 0
fi

if [ "$FORCE" -ne 1 ]; then
  printf '确认回滚？会一并丢掉 duration-refresh 的改动 [y/N] '
  read -r ans </dev/tty || ans=""
  case "$ans" in
    y|Y|yes|YES) ;;
    *) info "已取消。"; exit 0 ;;
  esac
fi

stamp="$(date +%Y%m%d-%H%M%S)"

# --- 回滚前再备份当前文件（可逆）---------------------------------------------
info "回滚前备份当前文件（时间戳 $stamp）..."
for pair in "${PAIRS[@]}"; do
  cont="${pair%%:*}"; name="${pair##*:}"
  docker cp "$CONTAINER:$cont" "./$name.pre_unpatch_$stamp" >/dev/null 2>&1 \
    && info "  备份 -> ./$name.pre_unpatch_$stamp" \
    || warn "  $cont 备份失败（继续）"
done

# --- 还原 ---------------------------------------------------------------------
IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null)"
[ -n "$IMAGE" ] || { err "取不到容器镜像名"; exit 4; }

tmpd="$(mktemp -d "${TMPDIR:-/tmp}/mm_unpatch.XXXXXX")" || { err "mktemp 失败"; exit 1; }
trap 'rm -rf "$tmpd"' EXIT

idx=0
for pair in "${PAIRS[@]}"; do
  cont="${pair%%:*}"; name="${pair##*:}"
  b="${srcs[$idx]}"; idx=$((idx+1))
  if [ -n "$b" ]; then
    docker cp "$b" "$CONTAINER:$cont" >/dev/null 2>&1 \
      && info "已还原 $name（来自备份）" \
      || { err "还原 $name 失败"; exit 5; }
  else
    # 从镜像原版取
    if docker run --rm --entrypoint cat "$IMAGE" "$cont" > "$tmpd/$name" 2>/dev/null \
       && [ -s "$tmpd/$name" ]; then
      docker cp "$tmpd/$name" "$CONTAINER:$cont" >/dev/null 2>&1 \
        && info "已还原 $name（来自镜像原版）" \
        || { err "还原 $name 失败"; exit 5; }
    else
      warn "  取不到镜像原版 $name，跳过。"
    fi
  fi
done

docker exec "$CONTAINER" python -m py_compile \
  "$CONT_MUSIC_LIB" "$CONT_MUSIC_ROUTER" "$CONT_DEVICE_PLAYER" "$CONT_XIAOMUSIC" >/dev/null 2>&1 \
  && info "容器内语法检查通过。" \
  || warn "容器内 py_compile 未通过，请留意启动日志。"

info "重启容器..."
docker restart "$CONTAINER" >/dev/null 2>&1 || { err "docker restart 失败"; exit 8; }

info "回滚完成。"
info "验证：curl -s http://<host>:<端口>/api/music-mgr/albums 应返回 404（补丁已移除）。"
info "如需再次使用，重跑 ./patch_music_manager.sh；若也要时长功能，另跑 duration-refresh 的补丁。"
exit 0
