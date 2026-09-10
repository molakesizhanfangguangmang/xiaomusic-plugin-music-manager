/* =========================================================================
 * 高级播放设置 —— tool.js
 * 读写后端 /api/music-mgr/adv-play-settings（由 music-manager 后端补丁提供）。
 * 三项彼此独立，改动各自即时保存。
 * ========================================================================= */
(function () {
  'use strict';

  var API = '/api/music-mgr/adv-play-settings';

  var swAll = document.getElementById('sw-all');
  var swOne = document.getElementById('sw-one');
  var swSilent = document.getElementById('sw-silent');
  var statusEl = document.getElementById('status');

  var statusTimer = null;

  function showStatus(msg, kind) {
    statusEl.textContent = msg;
    statusEl.className = 'ap-status show ' + (kind || 'info');
    if (statusTimer) { clearTimeout(statusTimer); }
    statusTimer = setTimeout(function () {
      statusEl.className = 'ap-status';
    }, 3200);
  }

  function render(settings) {
    swAll.checked = !!settings.auto_play_type_all;
    swOne.checked = !!settings.auto_play_type_one;
    swSilent.checked = !!settings.silent_switch_tts;
  }

  function load() {
    fetch(API, { method: 'GET' })
      .then(function (r) {
        if (!r.ok) { throw new Error('HTTP ' + r.status); }
        return r.json();
      })
      .then(function (d) {
        render(d.settings || {});
      })
      .catch(function (e) {
        showStatus('读取设置失败：' + e.message + '（后端补丁是否已打？）', 'err');
      });
  }

  function save() {
    var body = {
      auto_play_type_all: swAll.checked,
      auto_play_type_one: swOne.checked,
      silent_switch_tts: swSilent.checked
    };
    fetch(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    })
      .then(function (r) {
        if (!r.ok) { throw new Error('HTTP ' + r.status); }
        return r.json();
      })
      .then(function (d) {
        render(d.settings || {});
        showStatus('已保存', 'ok');
      })
      .catch(function (e) {
        showStatus('保存失败：' + e.message, 'err');
        load(); /* 回滚界面到服务端真实值 */
      });
  }

  swAll.addEventListener('change', save);
  swOne.addEventListener('change', save);
  swSilent.addEventListener('change', save);

  load();
})();
