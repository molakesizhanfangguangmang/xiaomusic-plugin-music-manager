#!/usr/bin/env bash
# =============================================================================
# patch_music_manager.sh — 给 xiaomusic 容器打上「歌曲管理」后端补丁
#
# 插件页需要四个官方 v0.6.1 镜像里不存在的端点，这些端点由本补丁引入：
#     POST /renamemusic
#     GET  /api/music-mgr/albums
#     POST /api/music-mgr/album/save
#     POST /api/music-mgr/album/delete
#     GET  /api/music-mgr/album/is-auto
# 同时修补两处播放器行为（见下）。没打补丁就装插件页，点按钮一律 404。
#
# 做的事（四件，都幂等）：
#   1) docker cp music_library.py -> <容器>:/app/xiaomusic/music_library.py
#        新增 rename_music()：改名 = 改磁盘文件 + 同步 tag.title / all_music 键
#            / tag_cache 键 / 重建 music_list（必须重建，否则面板与播放仍用旧名）
#        新增 _music_mgr_dir() / _album_filename()：专辑记账的目录与文件名映射
#        新增 read_album_records() / write_album_record() / delete_album_record()
#            / is_auto_album()：专辑记账的读写删与「自动专辑」判定
#        （并补 datetime + hashlib 两个 import）
#   2) docker cp music.py -> <容器>:/app/xiaomusic/api/routers/music.py
#        新增上述五个路由，全部薄封装到 music_library 对应方法
#   3) docker cp device_player.py -> <容器>:/app/xiaomusic/device_player.py
#        修「播放歌单X」误下载：play_music_list 未指定歌时校验记忆值是否属于
#        该歌单，不属于则丢弃并回退到 _play_list[0]，且 allow_download=False
#   4) docker cp xiaomusic.py -> <容器>:/app/xiaomusic/xiaomusic.py
#        修「删歌后记忆残留」：del_music 末尾调用 _purge_deleted_music_memory，
#        把已删歌名从各设备的 cur_music / playlist2music 中清掉并落盘
#
# 幂等：覆盖同一批文件，重复执行结果一致（不会再叠加改动）。
# 回滚：unpatch_music_manager.sh 从镜像原版恢复这四个文件。
# 安全：写入前先把容器内四个文件拉回宿主机备份（含时间戳），并做 py_compile 校验。
#
# 【重要】基线交叉说明：
#   device_player.py 的基线【含】duration-refresh 插件的下载完成钩子、以及更早
#   的 UA + 320k 两处改动；music_library.py 的基线【含】duration-refresh 的
#   regen_duration_for / verify_and_fix_duration；music.py 的基线【含】
#   duration-refresh 的 POST /refreshtagbyname。
#   也就是说：本补丁是「在已含 duration-refresh 的基线上」继续做的，
#   两者不冲突、可共存（打本补丁不会让时长功能失效）；但反过来，
#   若先打本补丁再打 duration-refresh 的补丁，duration-refresh 的旧基线会
#   覆盖掉本补丁的 device_player.py / music.py / music_library.py 改动 ——
#   所以顺序是【先 duration-refresh，后 music-manager】。
#   回滚本补丁会一并丢掉 duration-refresh 的改动，若要保留需重打它的补丁。
#
# 用法：
#   ./patch_music_manager.sh                     # 默认容器名 xiaomusic
#   ./patch_music_manager.sh -c myxiaomusic
#   ./patch_music_manager.sh --dry-run
# =============================================================================

set -u

readonly MARK='cow: music-manager patch'
readonly CONT_APP='/app/xiaomusic'
readonly CONT_MUSIC_LIB="$CONT_APP/music_library.py"
readonly CONT_MUSIC_ROUTER="$CONT_APP/api/routers/music.py"
readonly CONT_DEVICE_PLAYER="$CONT_APP/device_player.py"
readonly CONT_XIAOMUSIC="$CONT_APP/xiaomusic.py"

readonly PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SRC_MUSIC_LIB="$PKG_DIR/music_library.py"
readonly SRC_MUSIC_ROUTER="$PKG_DIR/music.py"
readonly SRC_DEVICE_PLAYER="$PKG_DIR/device_player.py"
readonly SRC_XIAOMUSIC="$PKG_DIR/xiaomusic.py"

CONTAINER="${CONTAINER:-xiaomusic}"
DRY_RUN=0

info() { printf '\033[0;36m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--container) CONTAINER="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,60p' "$0"; exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

for f in "$SRC_MUSIC_LIB" "$SRC_MUSIC_ROUTER" "$SRC_DEVICE_PLAYER" "$SRC_XIAOMUSIC"; do
  [ -f "$f" ] || { err "找不到 $f（本脚本须与四个 .py 在同一 patch/ 目录）"; exit 3; }
done

command -v docker >/dev/null 2>&1 || { err "找不到 docker 命令"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || {
  err "找不到运行中的容器「$CONTAINER」；用 -c <名> 指定"; exit 1; }

# --- 补丁源文件自检：确认改动确实在文件里 -------------------------------------
grep -q 'def rename_music' "$SRC_MUSIC_LIB" \
  || { err "$SRC_MUSIC_LIB 缺少 rename_music，补丁文件不对"; exit 3; }
grep -q 'def write_album_record' "$SRC_MUSIC_LIB" \
  || { err "$SRC_MUSIC_LIB 缺少 write_album_record，补丁文件不对"; exit 3; }
grep -q 'def is_auto_album' "$SRC_MUSIC_LIB" \
  || { err "$SRC_MUSIC_LIB 缺少 is_auto_album，补丁文件不对"; exit 3; }
grep -q 'renamemusic' "$SRC_MUSIC_ROUTER" \
  || { err "$SRC_MUSIC_ROUTER 缺少 /renamemusic，补丁文件不对"; exit 3; }
grep -q 'music-mgr/album/is-auto' "$SRC_MUSIC_ROUTER" \
  || { err "$SRC_MUSIC_ROUTER 缺少 /api/music-mgr/album/is-auto，补丁文件不对"; exit 3; }
grep -q 'cow: 歌单【' "$SRC_DEVICE_PLAYER" \
  || { err "$SRC_DEVICE_PLAYER 缺少「播放歌单X」记忆归属校验，补丁文件不对"; exit 3; }
grep -q 'def _purge_deleted_music_memory' "$SRC_XIAOMUSIC" \
  || { err "$SRC_XIAOMUSIC 缺少 _purge_deleted_music_memory，补丁文件不对"; exit 3; }

tmpd="$(mktemp -d "${TMPDIR:-/tmp}/mm_patch.XXXXXX")" || { err "mktemp 失败"; exit 1; }
trap 'rm -rf "$tmpd"' EXIT

stamp="$(date +%Y%m%d-%H%M%S)"

# --- 备份容器内现有的四个文件 -------------------------------------------------
info "备份容器内现有文件（时间戳 $stamp）..."
for pair in "$CONT_MUSIC_LIB:music_library.py" \
            "$CONT_MUSIC_ROUTER:music.py" \
            "$CONT_DEVICE_PLAYER:device_player.py" \
            "$CONT_XIAOMUSIC:xiaomusic.py"; do
  cont="${pair%%:*}"; name="${pair##*:}"
  if docker cp "$CONTAINER:$cont" "./$name.bak_$stamp" >/dev/null 2>&1; then
    info "  备份 -> ./$name.bak_$stamp"
  else
    warn "  $cont 备份失败（继续）"
  fi
done

# --- 语法校验（宿主 python3）--------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  for f in "$SRC_MUSIC_LIB" "$SRC_MUSIC_ROUTER" "$SRC_DEVICE_PLAYER" "$SRC_XIAOMUSIC"; do
    if ! python3 -m py_compile "$f" >/dev/null 2>&1; then
      err "补丁文件语法检查未通过：$f；已中止，未写入容器。"; exit 6
    fi
  done
  info "语法检查通过。"
else
  warn "宿主无 python3，跳过语法检查（容器内仍可自行 py_compile）。"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] 将执行:"
  info "  docker cp '$SRC_MUSIC_LIB'     '$CONTAINER:$CONT_MUSIC_LIB'"
  info "  docker cp '$SRC_MUSIC_ROUTER'  '$CONTAINER:$CONT_MUSIC_ROUTER'"
  info "  docker cp '$SRC_DEVICE_PLAYER' '$CONTAINER:$CONT_DEVICE_PLAYER'"
  info "  docker cp '$SRC_XIAOMUSIC'     '$CONTAINER:$CONT_XIAOMUSIC'"
  info "  docker restart '$CONTAINER'"
  info "[dry-run] 未做任何写入。"
  exit 0
fi

# --- 写入容器 -----------------------------------------------------------------
info "拷入四个文件..."
docker cp "$SRC_MUSIC_LIB"     "$CONTAINER:$CONT_MUSIC_LIB"     >/dev/null 2>&1 || { err "拷入 music_library.py 失败"; exit 7; }
docker cp "$SRC_MUSIC_ROUTER"  "$CONTAINER:$CONT_MUSIC_ROUTER"  >/dev/null 2>&1 || { err "拷入 music.py 失败"; exit 7; }
docker cp "$SRC_DEVICE_PLAYER" "$CONTAINER:$CONT_DEVICE_PLAYER" >/dev/null 2>&1 || { err "拷入 device_player.py 失败"; exit 7; }
docker cp "$SRC_XIAOMUSIC"     "$CONTAINER:$CONT_XIAOMUSIC"     >/dev/null 2>&1 || { err "拷入 xiaomusic.py 失败"; exit 7; }

# 容器内再校验一次语法（有 python 就做）
docker exec "$CONTAINER" python -m py_compile \
  "$CONT_MUSIC_LIB" "$CONT_MUSIC_ROUTER" "$CONT_DEVICE_PLAYER" "$CONT_XIAOMUSIC" >/dev/null 2>&1 \
  && info "容器内语法检查通过。" \
  || warn "容器内 py_compile 未通过或不可用，请留意启动日志。"

info "重启容器使其生效..."
docker restart "$CONTAINER" >/dev/null 2>&1 || { err "docker restart 失败"; exit 8; }

info "完成（$MARK）。"
info "验证（应返回 JSON 而非 404）："
info "  curl -s http://<host>:<端口>/api/music-mgr/albums"
info "  curl -s http://<host>:<端口>/api/music-mgr/album/is-auto?album=<专辑名>"
info "备份：./*.bak_$stamp ；回滚用 ./unpatch_music_manager.sh"
exit 0
