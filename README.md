# xiaomusic 歌曲管理插件（music-manager）

给 [hanxi/xiaomusic](https://github.com/hanxi/xiaomusic)（v0.6.1）加一个「歌曲管理」工具页：
重命名歌曲、管理专辑、按歌手自动分类。

> 本插件由两部分组成：**一个插件页（zip）** + **一份后端补丁（四个 .py）**。
> 缺一个都不完整：只装页面点按钮全是 404，只打补丁没界面只能自己 curl。

---

## 功能

- **重命名**：改磁盘文件名的同时，把面板显示名、缓存键、列表键一并改掉。
  撞名拒绝、不覆盖；正在播的歌拒绝改名（弹窗带「停止播放」快捷按钮）。
  改名后必须重建列表，否则面板仍显示旧名（后端已处理）。
- **专辑管理**：查看/新建/删除专辑、增删专辑内歌曲。删专辑**只删歌单与记录，绝不删音频文件**。
- **自动分类**：按歌名里的 `-` 切分归组，点按钮先给出解析预览，可逐首改完再建专辑。
  追加式，不覆盖已有专辑。
- **高级设置**（页面右上角 ⚙）：查看/删除专辑记录文件。

### 自动分类规则

| 歌名形态 | 结果 |
|---|---|
| `歌名-歌手` 或 `歌名-歌手-系列` | 歌名 / 歌手（第 3 段起忽略） |
| 不含 `-` | 归入「未知歌手」专辑 |
| 歌手名含 `/`（多作者） | 归入「多作者，待分类」专辑 |

「未知歌手」与「多作者，待分类」是**两张独立的专辑**，不合并。

---

## 安装

### 前置条件

- 已在跑 xiaomusic v0.6.1 容器（默认容器名 `xiaomusic`，默认端口 `8090`/`58090`）。
- 已装工具区本体（`xiaomusic-tools-installer`），否则第二步无法通过页面上传。

### 第一步：打后端补丁（在宿主机执行）

补丁需要在宿主机跑，因为它要 `docker cp` 进容器再重启容器 —— 这是容器内部做不到的。

```sh
cd patches/music-manager/
./patch_music_manager.sh --dry-run   # 先看它要干什么
./patch_music_manager.sh             # 真打：备份 → docker cp → py_compile → restart
```

脚本会：备份容器内四个文件（带时间戳）→ 拷入四个 .py → 容器内 `py_compile` 校验 → 重启容器。
幂等，可重复执行。

### 第二步：装插件页

```sh
curl -X POST http://<host>:58090/api/xtools/upload -F "file=@music-manager-1.0.0.zip"
```

或走控制面板的「上传工具」页选 zip。装完首页「工具」入口会出现「歌曲管理」。

> **顺序不能反**：先打补丁再装页面。反了也能装，但点按钮全是 404。

### 验证

```sh
curl -s http://<host>:58090/api/music-mgr/albums
```

返回 JSON（而不是 404）即补丁在位。

### 回滚

```sh
cd patches/music-manager/
./unpatch_music_manager.sh
```

优先从 `patch_music_manager.sh` 留下的备份还原；没有备份则从镜像原版恢复。

---

## 补丁改了什么

补丁是**四个完整文件**（不是 diff），覆盖到容器对应位置。

### `music_library.py`

- `rename_music(old, new, update_title=True)` —— 改名主逻辑。同步磁盘文件、
  `tag.title`、`all_music` 键、`tag_cache` 键，最后调 `gen_all_music_list()`
  重建列表。顺序上必须**先落盘 tag_cache 再重建**，否则后台标签任务会读空 title
  覆盖掉，留下孤儿条目。
- `_music_mgr_dir()` / `_album_filename(album)` —— 专辑记录的目录与文件名映射。
- `read_album_records()` / `write_album_record()` / `delete_album_record()` —— 记录读写删。
- `is_auto_album(album)` —— 「自动专辑」判定，靠记录文件而非名字匹配。
- （补了 `datetime` + `hashlib` 两个 import。）

### `music.py`

新增五个路由，都是薄封装：

| 路由 | 作用 |
|---|---|
| `POST /renamemusic` | 改名 |
| `GET /api/music-mgr/albums` | 列出所有专辑记录 |
| `POST /api/music-mgr/album/save` | 写/更新一条专辑记录 |
| `POST /api/music-mgr/album/delete` | 删一条专辑记录 |
| `GET /api/music-mgr/album/is-auto` | 查询某专辑是否「自动专辑」 |

### `device_player.py`

- `play_music_list` —— 修「播放歌单X」误下载。未指定歌名时校验记忆值是否属于
  该歌单，不属于则丢弃并回退到 `_play_list[0]`，且 `allow_download=False`。
  空歌单直接拒绝播放，不再退化成拿 `cur_music` 去网络搜索下载。

### `xiaomusic.py`

- `del_music` 末尾新增 `_purge_deleted_music_memory(name)`：删歌后把该歌名从
  各设备的 `cur_music` / `playlist2music` 中清掉，并 `save_cur_config()` 落盘。
  不清理的话，下次「播放歌单X」会拿残留记忆值去找一个已不存在的文件，触发下载。

  注意实现细节：`device_manager.devices` 里装的是 `XiaoMusicDevice`（播放控制器），
  `cur_music` / `playlist2music` 挂在它的 `.device`（`Device` 配置对象）上，
  取属性要取对层，否则静默匹配不上。

---

## 与 duration-refresh 插件的关系

**两个插件的补丁共用同一批 xiaomusic 源文件**（`music_library.py` / `music.py` /
`device_player.py`）。本仓库的基线是「**已含 duration-refresh 改动**」的版本：

- `device_player.py` 含 duration-refresh 的下载完成时长钩子 + 更早的 UA/320k 改动
- `music_library.py` 含 `regen_duration_for` / `verify_and_fix_duration`
- `music.py` 含 `POST /refreshtagbyname`

后果：

- **两者可以共存** —— 打本补丁不会让时长功能失效（改动都在里面）。
- **只能一个顺序** —— 必须先 duration-refresh、后 music-manager。反过来的话，
  duration-refresh 的旧基线会覆盖掉本插件在这三个文件里的改动。
- **回滚本补丁会一并丢掉 duration-refresh 的改动**。要保留时长功能，回滚后重打它的补丁。

---

## 边界与已知取舍

- 删除专辑**绝不删音频文件**，只删歌单与记录。
- 改名后的名字**不能含 `/`**（会被 `os.path.join` 当成多级子目录，报
  `Errno 2 No such file or directory`）。当前由后端直接拒绝，不静默失败。
- 自动分类按 `-` 切分，歌手名本身含 `-` 时只解析出第一段（如
  `若娜瓦v4-HOYO-MIX` 只得到 `HOYO`）。这是简化取舍，界面上可逐首手动改。
- 专辑记录存放在容器挂载卷 `/app/conf/music-mgr/albums/<专辑名>.json`，
  重建容器不丢（`/app/conf` 是挂载卷）。
- 插件页运行在浏览器里，只能 fetch API + 用 localStorage，不能直接读写服务器文件系统。

---

## 目录结构

```
plugin/music-manager-1.0.0.zip           插件页（四文件：manifest/index/tool.css/tool.js）
patches/music-manager/music_library.py   补丁源：改名 + 专辑记录
patches/music-manager/music.py           补丁源：五个路由
patches/music-manager/device_player.py   补丁源：播放歌单修复
patches/music-manager/xiaomusic.py       补丁源：删歌记忆清理
patches/music-manager/patch_music_manager.sh     打补丁（幂等，支持 --dry-run）
patches/music-manager/unpatch_music_manager.sh   回滚
```

---

## 许可

AGPL-3.0。四个 `.py` 是 hanxi/xiaomusic 的直接修改版（上游 AGPL-3.0）；
插件页与脚本为原创，同样以 AGPL-3.0 分发。详见 [LICENSE](LICENSE)。
