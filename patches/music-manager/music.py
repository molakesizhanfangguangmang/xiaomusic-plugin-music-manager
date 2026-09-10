"""音乐管理路由"""

import base64
import json
import os
import urllib.parse

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Query,
    Request,
)
from fastapi.responses import RedirectResponse

from xiaomusic.api.dependencies import (
    log,
    verification,
    xiaomusic,
)
from xiaomusic.api.models import (
    DidPlayMusic,
    MusicInfoObj,
    MusicInfosQuery,
    MusicItem,
)

router = APIRouter(dependencies=[Depends(verification)])


@router.get("/searchmusic")
def searchmusic(name: str = ""):
    """搜索音乐"""
    return xiaomusic.music_library.searchmusic(name)


"""======================在线搜索相关接口============================="""


@router.get("/api/search/online")
async def search_online_music(
    keyword: str = Query(..., description="搜索关键词"),
    plugin: str = Query("all", description="指定插件名称，all表示搜索所有插件"),
    page: int = Query(1, description="页码"),
    limit: int = Query(20, description="每页数量"),
    api_type: int = Query(
        None, description="接口类型：1=MusicFree，2=LXServer"
    ),  # 🌟 接收前端传来的 api_type
):
    """在线音乐搜索API"""
    try:
        if not keyword:
            return {"success": False, "error": "Keyword required"}

        return await xiaomusic.get_music_list_online(
            keyword=keyword, plugin=plugin, page=page, limit=limit, api_type=api_type
        )
    except Exception as e:
        return {"success": False, "error": str(e)}


@router.get("/api/search/online_playlist")
async def search_online_playlist(
    keyword: str = Query(..., description="搜索关键词"),
    plugin: str = Query("all", description="指定平台名称"),
    page: int = Query(1, description="页码"),
    limit: int = Query(20, description="每页数量"),
    api_type: int = Query(None, description="接口类型：1=MusicFree，2=LXServer"),
):
    """在线歌单搜索API"""
    try:
        if not keyword:
            return {"success": False, "error": "Keyword required"}

        return await xiaomusic.get_playlist_online(
            keyword=keyword, plugin=plugin, page=page, limit=limit, api_type=api_type
        )
    except Exception as e:
        return {"success": False, "error": str(e)}


@router.get("/api/search/online_playlist_detail")
async def search_online_playlist_detail(
    id: str = Query(..., description="歌单ID"),
    plugin: str = Query(..., description="平台名称(如wy/kg)"),
    api_type: int = Query(..., description="接口类型：1=MusicFree，2=LXServer"),
):
    """在线歌单详情获取API (歌单转歌曲)"""
    try:
        # 逻辑上 id, plugin, api_type 均由 Query(...) 强制要求，无需额外 if 判断
        return await xiaomusic.get_playlist_detail_online(
            id=id, plugin=plugin, api_type=api_type
        )
    except Exception as e:
        return {"success": False, "error": str(e)}


@router.get("/api/proxy/real-url")
async def get_real_music_url(url: str = Query(..., description="原始url")):
    """通过服务端代理获取真实的URL，不止是音频url,可能还有图片url"""
    try:
        # 获取真实的URL
        real_url = await xiaomusic.get_real_url_of_openapi(url)
        # 直接重定向到真实URL
        return RedirectResponse(url=real_url)

    except Exception as e:
        log.error(f"获取真实URL失败: {e}")
        # 如果代理获取失败，重定向到原始URL
        return RedirectResponse(url=url)


@router.get("/api/proxy/plugin-url")
async def get_plugin_source_url(
    data: str = Query(..., description="json对象压缩的base64"),
):
    try:
        # 获取请求数据
        # 容错处理1：将 URL 传输中可能被误转为空格的 '+' 还原回去（win平台）
        data = data.replace(" ", "+")
        # 2. 容错处理：自动补全 Base64 缺失的 '=' 填充符（Linux平台）
        missing_padding = len(data) % 4
        if missing_padding:
            data += "=" * (4 - missing_padding)

        # 将Base64编码的URL解码为Json字符串
        json_str = base64.b64decode(data).decode("utf-8")
        # 将json字符串转换为json对象
        json_data = json.loads(json_str)
        # 调用公共函数处理
        media_source = await xiaomusic.online_music_service.get_media_source_url(
            json_data
        )
        if media_source and media_source.get("url"):
            source_url = media_source.get("url")
            log.info(f"plugin-url 成功解析: {json_data} -> {source_url}")
            return RedirectResponse(url=source_url)
        else:
            # 没有有效链接时，直接抛出 404 错误！
            log.warning(f"plugin-url 解析失败(链接为空): {json_data}")
            raise HTTPException(status_code=404, detail="获取真实音频链接为空")

    except HTTPException:
        # 允许 HTTPException 继续向上传递，确保 404 能被前线捕获
        raise
    except Exception as e:
        log.error(f"获取真实音乐URL失败: {e}")
        # 发生其他未知异常时，同样抛出错误
        raise HTTPException(status_code=404, detail=str(e)) from e


@router.post("/api/play/getMediaSource")
async def get_media_source(request: Request):
    """获取音乐真实播放URL"""
    try:
        # 获取请求数据
        data = await request.json()
        # 调用公共函数处理
        return await xiaomusic.online_music_service.get_media_source_url(data)
    except Exception as e:
        return {"success": False, "error": str(e)}


@router.post("/api/play/getLyric")
async def get_media_lyric(request: Request):
    """获取音乐歌词"""
    try:
        # 获取请求数据
        data = await request.json()
        # 调用公共函数处理
        return await xiaomusic.get_media_lyric(data)
    except Exception as e:
        return {"success": False, "error": str(e)}


@router.post("/api/device/pushUrl")
async def device_push_url(request: Request):
    """推送url给设备端播放"""
    try:
        # 获取请求数据
        data = await request.json()
        did = data.get("did")
        openapi_info = xiaomusic.js_plugin_manager.get_lx_server_info()
        if openapi_info.get("enabled", False):
            url = data.get("url")
        else:
            # 调用公共函数处理,获取音乐真实播放URL
            url = xiaomusic.get_plugin_proxy_url(data)
        decoded_url = urllib.parse.unquote(url)
        return await xiaomusic.play_url(did=did, arg1=decoded_url)
    except Exception as e:
        return {"success": False, "error": str(e)}


@router.post("/api/device/pushList")
async def device_push_list(request: Request):
    """WEB前端推送歌单给设备端播放"""
    try:
        # 获取请求数据
        data = await request.json()
        did = data.get("did")
        song_list = data.get("songList")
        list_name = data.get("playlistName")
        # 调用公共函数处理,处理歌曲信息 -> 添加歌单 -> 播放歌单
        return await xiaomusic.push_music_list_play(
            did=did, song_list=song_list, list_name=list_name
        )
    except Exception as e:
        return {"success": False, "error": str(e)}


"""======================在线搜索相关接口END============================="""


@router.get("/playingmusic")
def playingmusic(did: str = ""):
    """当前播放音乐"""
    if not xiaomusic.did_exist(did):
        return {"ret": "Did not exist"}

    is_playing = xiaomusic.isplaying(did)
    cur_music = xiaomusic.playingmusic(did)
    cur_playlist = xiaomusic.get_cur_play_list(did)
    # 播放进度
    offset, duration = xiaomusic.get_offset_duration(did)
    return {
        "ret": "OK",
        "is_playing": is_playing,
        "cur_music": cur_music,
        "cur_playlist": cur_playlist,
        "offset": offset,
        "duration": duration,
    }


@router.get("/musiclist")
async def musiclist():
    """音乐列表"""
    return xiaomusic.music_library.get_music_list()


@router.get("/musicinfo")
async def musicinfo(name: str, musictag: bool = False):
    """音乐信息"""
    url, _ = await xiaomusic.music_library.get_music_url(name)
    info = {
        "ret": "OK",
        "name": name,
        "url": url,
    }
    if musictag:
        info["tags"] = await xiaomusic.music_library.get_music_tags(name)
    return info


@router.get("/musicinfos")
async def musicinfos(
    name: list[str] = Query(None),
    musictag: bool = False,
):
    """批量音乐信息"""
    ret = []
    for music_name in name:
        url, _ = await xiaomusic.music_library.get_music_url(music_name)
        info = {
            "name": music_name,
            "url": url,
        }
        if musictag:
            info["tags"] = await xiaomusic.music_library.get_music_tags(music_name)
        ret.append(info)
    return ret


@router.post("/musicinfos")
async def musicinfos_post(data: MusicInfosQuery):
    """批量音乐信息（POST，避免 URL 过长）"""
    ret = []
    for music_name in data.name:
        url, _ = await xiaomusic.music_library.get_music_url(music_name)
        info = {
            "name": music_name,
            "url": url,
        }
        if data.musictag:
            info["tags"] = await xiaomusic.music_library.get_music_tags(music_name)
        ret.append(info)
    return ret


@router.post("/setmusictag")
async def setmusictag(info: MusicInfoObj):
    """设置音乐标签"""
    ret = xiaomusic.music_library.set_music_tag(info.musicname, info)
    return {"ret": ret}


@router.post("/delmusic")
async def delmusic(data: MusicItem):
    """删除音乐"""
    log.info(data)
    await xiaomusic.del_music(data.name)
    return "success"


@router.post("/playmusic")
async def playmusic(data: DidPlayMusic):
    """播放音乐"""
    did = data.did
    musicname = data.musicname
    searchkey = data.searchkey
    if not xiaomusic.did_exist(did):
        return {"ret": "Did not exist"}

    log.info(f"playmusic {did} musicname:{musicname} searchkey:{searchkey}")
    await xiaomusic.do_play(did, musicname, searchkey)
    return {"ret": "OK"}


@router.post("/refreshmusictag")
async def refreshmusictag(Verifcation=Depends(verification)):
    """刷新音乐标签"""
    xiaomusic.music_library.refresh_music_tag()
    return {
        "ret": "OK",
    }


@router.post("/refreshtagbyname")
async def refreshtagbyname(data: MusicInfosQuery):
    """按名单重算时长（cow duration-refresh 补丁）

    全选/部分选/单选都只是 data.name 数组的长度差异。
    同步返回：算完才返回，逐首给新旧值。
    """
    results = await xiaomusic.music_library.regen_duration_for(data.name)
    return {
        "ret": "OK",
        "count": len(results),
        "changed": sum(1 for r in results if r["old"] != r["new"]),
        "items": results,
    }


@router.post("/debug_play_by_music_url")
async def debug_play_by_music_url(request: Request, Verifcation=Depends(verification)):
    """调试播放音乐URL"""
    try:
        data = await request.body()
        data_dict = json.loads(data.decode("utf-8"))
        log.info(f"data:{data_dict}")
        return await xiaomusic.debug_play_by_music_url(arg1=data_dict)
    except json.JSONDecodeError as err:
        raise HTTPException(status_code=400, detail="Invalid JSON") from err


@router.post("/api/music/refreshlist")
async def refreshlist(Verifcation=Depends(verification)):
    """刷新歌曲列表"""
    await xiaomusic.gen_music_list()
    return {
        "ret": "OK",
    }


@router.post("/scan_orphan_tags")
async def scan_orphan_tags():
    """扫描 tag cache 里的孤儿条目（cow orphan-cleaner 补丁）

    只扫描列出，不删除。返回 cache 有、磁盘上无的条目，供前端勾选。
    网络音乐条目一律跳过（它本就不落盘，按"文件不存在"判会全部误报）。

    注意：本端点不接受请求体。曾误绑 MusicInfosQuery，但该模型 name 为必填，
    前端发 {} 会被 Pydantic 判 422。扫描不需要任何入参，故不声明 body 参数。
    """
    result = xiaomusic.music_library.scan_orphan_tags()
    return {
        "ret": "OK",
        "orphan_count": len(result["orphans"]),
        "summary": result["summary"],
        "orphans": result["orphans"],
    }


@router.post("/delete_orphan_tags")
async def delete_orphan_tags(data: MusicInfosQuery):
    """删除指定的孤儿条目（cow orphan-cleaner 补丁）

    只删 tag cache 条目，不碰 download/ 下的实体文件。
    安全冗余：磁盘上仍存在的曲子会被拒绝删除。
    """
    results = xiaomusic.music_library.delete_orphan_tags(data.name)
    return {
        "ret": "OK",
        "count": len(results),
        "deleted": sum(1 for r in results if r["status"] == "ok"),
        "items": results,
    }


# ==================== 歌曲管理（cow music-manager 补丁） ====================


async def _read_json_body(request: Request):
    """读请求体 json；空体返回 {}。"""
    raw = await request.body()
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as err:
        raise HTTPException(status_code=400, detail="Invalid JSON") from err


@router.post("/renamemusic")
async def renamemusic(request: Request):
    """把一首歌改名（cow music-manager 补丁）

    body: {"old": "原名", "new": "新名", "update_title": true}

    改名会同步四方：磁盘文件、all_music、tag cache、所有自定义歌单引用。
    撞名拒绝、网络音乐拒绝、磁盘无文件拒绝。
    """
    data = await _read_json_body(request)
    old = data.get("old")
    new = data.get("new")
    update_title = data.get("update_title", True)
    if not old:
        raise HTTPException(status_code=400, detail="missing 'old'")
    result = xiaomusic.music_library.rename_music(old, new, update_title)
    return {"ret": "OK", **result}


@router.get("/api/music-mgr/albums")
async def music_mgr_list_albums():
    """列出全部自动专辑记账（cow music-manager 补丁）"""
    records = xiaomusic.music_library.read_album_records()
    return {"ret": "OK", "count": len(records), "albums": records}


@router.post("/api/music-mgr/album/save")
async def music_mgr_save_album(request: Request):
    """写一个专辑的记账（cow music-manager 补丁）

    body: {"album": "蔡琴", "auto": true, "songs": ["...", "..."]}
    只写记账文件，不动歌单、不动音频。
    """
    data = await _read_json_body(request)
    album = data.get("album")
    if not album:
        raise HTTPException(status_code=400, detail="missing 'album'")
    rec = xiaomusic.music_library.write_album_record(
        album, auto=data.get("auto", True), songs=data.get("songs", [])
    )
    return {"ret": "OK", "record": rec}


@router.post("/api/music-mgr/album/delete")
async def music_mgr_delete_album(request: Request):
    """删一个专辑的记账（cow music-manager 补丁）

    body: {"album": "蔡琴", "delete_playlist": true}

    **只删记账文件**；delete_playlist 为真时顺带删同名歌单（走歌单 API）。
    任何情况下都不动音频文件。
    """
    data = await _read_json_body(request)
    album = data.get("album")
    if not album:
        raise HTTPException(status_code=400, detail="missing 'album'")

    removed = xiaomusic.music_library.delete_album_record(album)
    playlist_removed = False
    if data.get("delete_playlist"):
        try:
            xiaomusic.music_library.play_list_del(album)
            playlist_removed = True
        except Exception as e:
            log.warning(f"删歌单失败 {album}: {e}")

    return {
        "ret": "OK",
        "record_removed": removed,
        "playlist_removed": playlist_removed,
    }


@router.get("/api/music-mgr/album/is-auto")
async def music_mgr_is_auto(album: str = Query(...)):
    """查一个专辑是否是自动生成的（cow music-manager 补丁）"""
    return {
        "ret": "OK",
        "album": album,
        "auto": xiaomusic.music_library.is_auto_album(album),
    }


# ---- cow music-manager 补丁：高级播放设置 ---------------------------------
#
# 设置文件 <music_mgr_dir>/settings.json，全局一份（不分设备）。
# 每个设备各自有一份进程内缓存，所以写完之后要让所有设备的缓存都失效，
# 否则改了开关得重启才生效。


def _adv_settings_path():
    try:
        base = xiaomusic.music_library._music_mgr_dir()
    except Exception:
        base = "/app/conf/music-mgr"
    return os.path.join(base, "settings.json")


def _read_adv_settings_raw():
    path = _adv_settings_path()
    data = {
        "auto_play_type_all": False,
        "auto_play_type_one": False,
        "silent_switch_tts": False,
    }
    try:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                raw = json.load(f)
            if isinstance(raw, dict):
                for k in data:
                    if k in raw:
                        data[k] = bool(raw[k])
                # 旧版合并键迁移（同 device_player.get_adv_settings 的规则）
                if (
                    "auto_play_type" in raw
                    and "auto_play_type_all" not in raw
                    and "auto_play_type_one" not in raw
                ):
                    legacy = bool(raw["auto_play_type"])
                    data["auto_play_type_all"] = legacy
                    data["auto_play_type_one"] = legacy
    except Exception as e:
        log.warning(f"cow: 读取高级播放设置失败: {e}")
    return data


def _write_adv_settings_raw(data):
    path = _adv_settings_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    return path


def _invalidate_all_adv_settings():
    for dev in xiaomusic.device_manager.devices.values():
        try:
            dev.invalidate_adv_settings()
        except Exception as e:
            log.warning(f"cow: 清设置缓存失败: {e}")


@router.get("/api/music-mgr/adv-play-settings")
async def music_mgr_get_adv_settings():
    """读高级播放设置（cow music-manager 补丁）"""
    return {"ret": "OK", "settings": _read_adv_settings_raw()}


@router.post("/api/music-mgr/adv-play-settings")
async def music_mgr_set_adv_settings(request: Request):
    """写高级播放设置（cow music-manager 补丁）

    body: {"auto_play_type_all": true, "auto_play_type_one": false,
           "silent_switch_tts": false}
    只接受已知字段；未传的字段保持原值。
    """
    data = await _read_json_body(request)
    cur = _read_adv_settings_raw()
    for k in cur:
        if k in data:
            cur[k] = bool(data[k])
    path = _write_adv_settings_raw(cur)
    _invalidate_all_adv_settings()
    log.info(f"cow: 高级播放设置已更新 {cur} -> {path}")
    return {"ret": "OK", "settings": cur}
