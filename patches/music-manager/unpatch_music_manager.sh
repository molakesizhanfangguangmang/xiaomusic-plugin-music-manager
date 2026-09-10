#!/usr/bin/env bash
# =============================================================================
# unpatch_music_manager.sh — 回滚「歌曲管理」后端补丁
#
# 还原内容：
#   /app/xiaomusic/music_library.py
#   /app/xiaomusic/api/routers/music.py
#   /app/xiaomusic/device_player.py
#   /app/xiaomusic/xiaomusic.py
#   /app/xiaomusic/static/default/index.html   （删掉追加进来的注入行）
#   并删除 /app/xiaomusic/static/xiaomusic_tools/adv-play/ 与 entry/adv-play-entry.js
#
# 还原来源优先级：
#   1) 本目录下最近的 *.bak_<时间戳> 备份（patch_music_manager.sh 留下的）
#   2) 没有备份时，从镜像原版恢复（docker run --rm 同镜像 cat 出来）
#
# 主页 index.html 若没有备份：不整文件覆盖，只把标记行删掉（保守做法，
#   避免用旧版本覆盖掉用户/其它插件在上面的改动）。
#
# 【注意】还原会一并丢掉 duration-refresh 插件的改动（共用同一批文件）。
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
readonly CONT_INDEX="$CONT_APP/static/default/index.html"
readonly CONT_ADV_DIR="$CONT_APP/static/xiaomusic_tools/adv-play"
readonly CONT_ENTRY_JS="$CONT_APP/static/xiaomusic_tools/entry/adv-play-entry.js"

readonly INDEX_MARK='advplay_entry'

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
    -h|--help)      sed -n '2,32p' "$0"; exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { err "找不到 docker 命令"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || {
  err "找不到运行中的容器「$CONTAINER」；用 -c <名> 指定"; exit 1; }

# --- 找最近的备份 -------------------------------------------------------------
find_backup() {
  ls -1 "$PKG_DIR/$1".bak_* 2>/dev/null | sort | tail -n 1
}

declare -a PAIRS=(
  "$CONT_MUSIC_LIB:music_library.py"
  "$CONT_MUSIC_ROUTER:music.py"
  "$CONT_DEVICE_PLAYER:device_player.py"
  "$CONT_XIAOMUSIC:xiaomusic.py"
  "$CONT_INDEX:index.html"
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
echo "    另删除 $CONT_ADV_DIR/ 与 $CONT_ENTRY_JS"
if [ ! -f "$(find_backup index.html)" ]; then
  echo "    主页无备份，将只删除标记行（不整文件覆盖）"
fi
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

# --- 还原 .py 与主页 ----------------------------------------------------------
IMAGE="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null)"
[ -n "$IMAGE" ] || { err "取不到容器镜像名"; exit 4; }

tmpd="$(mktemp -d "${TMPDIR:-/tmp}/mm_unpatch.XXXXXX")" || { err "mktemp 失败"; exit 1; }
trap 'rm -rf "$tmpd"' EXIT

idx=0
for pair in "${PAIRS[@]}"; do
  cont="${pair%%:*}"; name="${pair##*:}"
  b="${srcs[$idx]}"; idx=$((idx+1))

  # 主页和 .py 的处理分开：主页在无备份时只删标记行，不做整文件覆盖
  if [ "$name" = "index.html" ] && [ -z "$b" ]; then
    info "主页无备份：只删除标记行"
    if docker exec "$CONTAINER" grep -q "$INDEX_MARK" "$CONT_INDEX" >/dev/null 2>&1; then
      if docker exec "$CONTAINER" sh -c \
        "grep -v '$INDEX_MARK' '$CONT_INDEX' > '$CONT_INDEX.tmp' && mv '$CONT_INDEX.tmp' '$CONT_INDEX'"; then
        info "  标记行已删除。"
      else
        warn "  标记行删除失败，请手动检查 $CONT_INDEX"
      fi
    else
      info "  主页本就没有标记行，跳过。"
    fi
    continue
  fi

  if [ -n "$b" ]; then
    docker cp "$b" "$CONTAINER:$cont" >/dev/null 2>&1 \
      && info "已还原 $name（来自备份）" \
      || { err "还原 $name 失败"; exit 5; }
  else
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

# --- 删除高级设置页与注入器 ---------------------------------------------------
info "删除高级设置页与注入器..."
docker exec "$CONTAINER" rm -rf "$CONT_ADV_DIR" >/dev/null 2>&1 \
  && info "  已删 $CONT_ADV_DIR" || warn "  删除 $CONT_ADV_DIR 失败（可能本就不存在）"
docker exec "$CONTAINER" rm -f "$CONT_ENTRY_JS" >/dev/null 2>&1 \
  && info "  已删 $CONT_ENTRY_JS" || warn "  删除 $CONT_ENTRY_JS 失败（可能本就不存在）"

docker exec "$CONTAINER" python -m py_compile \
  "$CONT_MUSIC_LIB" "$CONT_MUSIC_ROUTER" "$CONT_DEVICE_PLAYER" "$CONT_XIAOMUSIC" >/dev/null 2>&1 \
  && info "容器内语法检查通过。" \
  || warn "容器内 py_compile 未通过，请留意启动日志。"

info "重启容器..."
docker restart "$CONTAINER" >/dev/null 2>&1 || { err "docker restart 失败"; exit 8; }

info "回滚完成。"
info "验证：curl -s http://<host>:58090/api/music-mgr/albums 应返回 404（补丁已移除）。"
info "如需再次使用，重跑 ./patch_music_manager.sh；若也要时长功能，另跑 duration-refresh 的补丁。"
exit 0
