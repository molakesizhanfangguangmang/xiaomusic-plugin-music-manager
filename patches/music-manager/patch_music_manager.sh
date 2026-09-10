#!/usr/bin/env bash
# =============================================================================
# patch_music_manager.sh — 给 xiaomusic 容器打上「歌曲管理」后端补丁
#
# 补丁给 xiaomusic 加：
#   1. 四个新端点（官方 v0.6.1 镜像里没有，插件页需要它们）：
#        POST /renamemusic
#        GET  /api/music-mgr/albums
#        POST /api/music-mgr/album/save
#        POST /api/music-mgr/album/delete
#        GET  /api/music-mgr/album/is-auto
#        GET/POST /api/music-mgr/adv-play-settings   （高级播放设置读写）
#   2. 三处播放器行为修补：
#        play_music_list  修「播放歌单X」误下载；播歌单自动切列表循环
#        play             播单曲自动切单曲循环
#        del_music        删歌后清理 cur_music / playlist2music 残留记忆
#   3. 主控制面板新增「高级播放设置」入口（幻彩图标，与「工具」并排）
#
# 没打补丁就装插件页，点按钮一律 404。
#
# 做的事（都幂等）：
#   A) docker cp 四个 .py  -> 容器 /app/xiaomusic/ 与 /api/routers/
#   B) docker cp 高级设置页三件 -> /app/xiaomusic/static/xiaomusic_tools/adv-play/
#   C) docker cp 注入器       -> /app/xiaomusic/static/xiaomusic_tools/entry/
#   D) 往主页 /app/xiaomusic/static/default/index.html 末尾追加一行 script 引用
#      （仅在尚不存在该行时追加，重复执行不会追加第二次）
#   E) 重启容器
#
# 幂等：A~D 重复执行结果一致。回滚见 unpatch_music_manager.sh。
# 安全：写入前先把容器内被覆盖的文件拉回宿主机备份（含时间戳），并做语法校验。
#
# 【重要】基线交叉说明：
#   四个 .py 的基线【含】duration-refresh 插件的改动（下载完成时长钩子、
#   regen_duration_for、POST /refreshtagbyname 等），两者共用同一批 xiaomusic
#   源文件。可共存；但安装顺序须【先 duration-refresh，后 music-manager】。
#   回滚本补丁会一并丢掉 duration-refresh 的改动。
#
# 用法：
#   ./patch_music_manager.sh                     # 默认容器名 xiaomusic
#   ./patch_music_manager.sh -c myxiaomusic
#   ./patch_music_manager.sh --dry-run
# =============================================================================

set -u

readonly CONT_APP='/app/xiaomusic'
readonly CONT_MUSIC_LIB="$CONT_APP/music_library.py"
readonly CONT_MUSIC_ROUTER="$CONT_APP/api/routers/music.py"
readonly CONT_DEVICE_PLAYER="$CONT_APP/device_player.py"
readonly CONT_XIAOMUSIC="$CONT_APP/xiaomusic.py"
readonly CONT_INDEX="$CONT_APP/static/default/index.html"
readonly CONT_ADV_DIR="$CONT_APP/static/xiaomusic_tools/adv-play"
readonly CONT_ENTRY_DIR="$CONT_APP/static/xiaomusic_tools/entry"

# 主页要追加的那一行（含前后换行，便于精确追加与删除）
readonly INDEX_LINE='<!--advplay_entry--><script src="/static/xiaomusic_tools/entry/adv-play-entry.js"></script>'
readonly INDEX_MARK='advplay_entry'

readonly PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SRC_MUSIC_LIB="$PKG_DIR/music_library.py"
readonly SRC_MUSIC_ROUTER="$PKG_DIR/music.py"
readonly SRC_DEVICE_PLAYER="$PKG_DIR/device_player.py"
readonly SRC_XIAOMUSIC="$PKG_DIR/xiaomusic.py"
readonly SRC_ADV_DIR="$PKG_DIR/adv-play"
readonly SRC_ENTRY_JS="$PKG_DIR/entry/adv-play-entry.js"

CONTAINER="${CONTAINER:-xiaomusic}"
DRY_RUN=0

info() { printf '\033[0;36m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--container) CONTAINER="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,55p' "$0"; exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

for f in "$SRC_MUSIC_LIB" "$SRC_MUSIC_ROUTER" "$SRC_DEVICE_PLAYER" "$SRC_XIAOMUSIC" \
         "$SRC_ADV_DIR/index.html" "$SRC_ADV_DIR/tool.css" "$SRC_ADV_DIR/tool.js" \
         "$SRC_ENTRY_JS"; do
  [ -f "$f" ] || { err "找不到 $f（本脚本须与补丁文件保持同目录结构）"; exit 3; }
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
grep -q 'music-mgr/adv-play-settings' "$SRC_MUSIC_ROUTER" \
  || { err "$SRC_MUSIC_ROUTER 缺少 /api/music-mgr/adv-play-settings，补丁文件不对"; exit 3; }
grep -q 'cow: 歌单【' "$SRC_DEVICE_PLAYER" \
  || { err "$SRC_DEVICE_PLAYER 缺少「播放歌单X」记忆归属校验，补丁文件不对"; exit 3; }
grep -q '_ADV_SWITCH_KEY_BY_TYPE' "$SRC_DEVICE_PLAYER" \
  || { err "$SRC_DEVICE_PLAYER 缺少高级播放设置开关映射，补丁文件不对"; exit 3; }
grep -q 'def _purge_deleted_music_memory' "$SRC_XIAOMUSIC" \
  || { err "$SRC_XIAOMUSIC 缺少 _purge_deleted_music_memory，补丁文件不对"; exit 3; }

# --- 备份容器内现有的文件 -----------------------------------------------------
stamp="$(date +%Y%m%d-%H%M%S)"

info "备份容器内现有文件（时间戳 $stamp）..."
for pair in "$CONT_MUSIC_LIB:music_library.py" \
            "$CONT_MUSIC_ROUTER:music.py" \
            "$CONT_DEVICE_PLAYER:device_player.py" \
            "$CONT_XIAOMUSIC:xiaomusic.py" \
            "$CONT_INDEX:index.html"; do
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

# 主页是否已含注入行（决定 D 步要不要做）
HAS_LINE=0
if docker exec "$CONTAINER" grep -q "$INDEX_MARK" "$CONT_INDEX" >/dev/null 2>&1; then
  HAS_LINE=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] 将执行:"
  info "  docker cp '$SRC_MUSIC_LIB'     '$CONTAINER:$CONT_MUSIC_LIB'"
  info "  docker cp '$SRC_MUSIC_ROUTER'  '$CONTAINER:$CONT_MUSIC_ROUTER'"
  info "  docker cp '$SRC_DEVICE_PLAYER' '$CONTAINER:$CONT_DEVICE_PLAYER'"
  info "  docker cp '$SRC_XIAOMUSIC'     '$CONTAINER:$CONT_XIAOMUSIC'"
  info "  docker cp '$SRC_ADV_DIR'       '$CONTAINER:$CONT_ADV_DIR'"
  info "  docker cp '$SRC_ENTRY_JS'      '$CONTAINER:$CONT_ENTRY_DIR/'"
  if [ "$HAS_LINE" -eq 1 ]; then
    info "  主页已含注入行，跳过追加"
  else
    info "  向 $CONT_INDEX 末尾追加 $INDEX_LINE"
  fi
  info "  docker restart '$CONTAINER'"
  info "[dry-run] 未做任何写入。"
  exit 0
fi

# --- A) 四个 .py ---------------------------------------------------------------
info "拷入四个后端文件..."
docker cp "$SRC_MUSIC_LIB"     "$CONTAINER:$CONT_MUSIC_LIB"     >/dev/null 2>&1 || { err "拷入 music_library.py 失败"; exit 7; }
docker cp "$SRC_MUSIC_ROUTER"  "$CONTAINER:$CONT_MUSIC_ROUTER"  >/dev/null 2>&1 || { err "拷入 music.py 失败"; exit 7; }
docker cp "$SRC_DEVICE_PLAYER" "$CONTAINER:$CONT_DEVICE_PLAYER" >/dev/null 2>&1 || { err "拷入 device_player.py 失败"; exit 7; }
docker cp "$SRC_XIAOMUSIC"     "$CONTAINER:$CONT_XIAOMUSIC"     >/dev/null 2>&1 || { err "拷入 xiaomusic.py 失败"; exit 7; }

# --- B) 高级设置页 -------------------------------------------------------------
info "部署高级播放设置页..."
docker exec "$CONTAINER" mkdir -p "$CONT_ADV_DIR" >/dev/null 2>&1
docker cp "$SRC_ADV_DIR/index.html" "$CONTAINER:$CONT_ADV_DIR/index.html" >/dev/null 2>&1 || { err "拷入 adv-play/index.html 失败"; exit 7; }
docker cp "$SRC_ADV_DIR/tool.css"   "$CONTAINER:$CONT_ADV_DIR/tool.css"   >/dev/null 2>&1 || { err "拷入 adv-play/tool.css 失败"; exit 7; }
docker cp "$SRC_ADV_DIR/tool.js"    "$CONTAINER:$CONT_ADV_DIR/tool.js"    >/dev/null 2>&1 || { err "拷入 adv-play/tool.js 失败"; exit 7; }

# --- C) 注入器 -----------------------------------------------------------------
info "部署主页入口注入器..."
docker exec "$CONTAINER" mkdir -p "$CONT_ENTRY_DIR" >/dev/null 2>&1
docker cp "$SRC_ENTRY_JS" "$CONTAINER:$CONT_ENTRY_DIR/adv-play-entry.js" >/dev/null 2>&1 \
  || { err "拷入 adv-play-entry.js 失败"; exit 7; }

# --- D) 主页追加一行（幂等）----------------------------------------------------
if [ "$HAS_LINE" -eq 1 ]; then
  info "主页已含注入行，跳过追加。"
else
  info "向主页追加注入行..."
  # 用一次 docker exec sh -c 完成：把要追加的内容经 stdin 传进去更稳妥，
  # 这里内容简单无特殊字符，用 printf 直接写。
  if docker exec "$CONTAINER" sh -c "printf '\n%s\n' '$INDEX_LINE' >> '$CONT_INDEX'"; then
    info "  已追加。"
  else
    err "主页追加失败"; exit 9
  fi
fi

# 容器内 py_compile 再校验一次
docker exec "$CONTAINER" python -m py_compile \
  "$CONT_MUSIC_LIB" "$CONT_MUSIC_ROUTER" "$CONT_DEVICE_PLAYER" "$CONT_XIAOMUSIC" >/dev/null 2>&1 \
  && info "容器内语法检查通过。" \
  || warn "容器内 py_compile 未通过或不可用，请留意启动日志。"

# --- E) 重启 -------------------------------------------------------------------
info "重启容器使其生效..."
docker restart "$CONTAINER" >/dev/null 2>&1 || { err "docker restart 失败"; exit 8; }

info "完成。"
info "验证（应返回 JSON 而非 404）："
info "  curl -s http://<host>:58090/api/music-mgr/albums"
info "  curl -s http://<host>:58090/api/music-mgr/adv-play-settings"
info "  主页图标行应多出「高级播放设置」（幻彩图标）"
info "备份：./*.bak_$stamp ；回滚用 ./unpatch_music_manager.sh"
exit 0
