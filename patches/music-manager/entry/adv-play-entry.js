/* adv-play-entry.js —— xiaomusic default 主控制面板「高级播放设置」入口注入器
 *
 * 与同目录的 tools-entry.js 同构（同一套注入模式，便于维护与统一回滚）。
 * 唯一的任务：在 default 主控制面板(default/index.html) 的
 * 「设备功能入口行 .mode-controls.button-group」末尾 append 一个
 * 「高级播放设置」图标入口，点击跳转到固定页
 *   /static/xiaomusic_tools/adv-play/index.html
 *
 * 与 tools-entry.js 的区别（有意为之）：
 *   1. 图标用内联 SVG 而非 Material Icons 字形 —— 需要渐变填充（幻彩），
 *      字形是单色字体，做不到渐变；且 SVG 不依赖字体是否含该字形。
 *   2. 有自己的 MARK 属性值，两个注入器各注入各的，互不干扰。
 *
 * 部署：在主页文件最末尾、</body> 前追加唯一一行 script 引用
 *   <script src="/static/xiaomusic_tools/entry/adv-play-entry.js"></script>
 * 回滚 = 删掉该行（页面本体另见 xiaomusic_tools/adv-play/）。
 *
 * 作用域约定：本文件不定义任何全局；不改 md.js 的任何函数；只在自身节点上挂
 *   click 监听，不向 .mode-controls 或其父容器委托事件。
 */
(function () {
  'use strict';

  /* 固定地址：显式 index.html（StaticFiles 不自动回退目录 index，实测裸目录 404）。 */
  var PAGE_HOME = '/static/xiaomusic_tools/adv-play/index.html';

  /* 注入标记：避免重复注入；与 tools-entry.js 用不同的标记值。 */
  var MARK_ATTR = 'data-advplay-entry';
  var MARK_VAL = '1';

  /* 幻彩图标：内联 SVG，用 linearGradient 做渐变描边。
     渐变色与工具页的幻彩配色同一色系（青 -> 紫 -> 粉）。 */
  var ICON_SVG =
    '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true" ' +
    'style="display:block;margin:0 auto;">' +
    '<defs>' +
    '<linearGradient id="advplay-grad" x1="0%" y1="0%" x2="100%" y2="100%">' +
    '<stop offset="0%" stop-color="#4dd0e1"/>' +
    '<stop offset="50%" stop-color="#9575cd"/>' +
    '<stop offset="100%" stop-color="#f06292"/>' +
    '</linearGradient>' +
    '</defs>' +
    /* 循环箭头（播放模式） */
    '<path d="M7 7h9a4 4 0 0 1 4 4" fill="none" ' +
    'stroke="url(#advplay-grad)" stroke-width="2" stroke-linecap="round"/>' +
    '<path d="M9.5 4.5 7 7l2.5 2.5" fill="none" ' +
    'stroke="url(#advplay-grad)" stroke-width="2" stroke-linecap="round" ' +
    'stroke-linejoin="round"/>' +
    '<path d="M17 17H8a4 4 0 0 1-4-4" fill="none" ' +
    'stroke="url(#advplay-grad)" stroke-width="2" stroke-linecap="round"/>' +
    '<path d="M14.5 19.5 17 17l-2.5-2.5" fill="none" ' +
    'stroke="url(#advplay-grad)" stroke-width="2" stroke-linecap="round" ' +
    'stroke-linejoin="round"/>' +
    '</svg>';

  function inject() {
    var host = document.querySelector('.mode-controls.button-group');
    if (!host) { return; }
    if (host.querySelector('[' + MARK_ATTR + '="' + MARK_VAL + '"]')) { return; }

    var btn = document.createElement('div');
    btn.className = 'icon-item device-enable';
    btn.setAttribute(MARK_ATTR, MARK_VAL);
    btn.setAttribute('role', 'button');
    btn.setAttribute('aria-label', '高级播放设置');

    var span = document.createElement('span');
    span.className = 'material-icons';
    span.setAttribute('aria-hidden', 'true');
    span.innerHTML = ICON_SVG;
    btn.appendChild(span);

    var p = document.createElement('p');
    p.textContent = '高级播放设置';
    /* 名字较长，略微缩小以免撑破图标格 */
    p.style.fontSize = '12px';
    btn.appendChild(p);

    btn.addEventListener('click', function () {
      window.location.href = PAGE_HOME;
    });
    btn.tabIndex = 0;

    host.appendChild(btn);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', inject);
  } else {
    inject();
  }
})();
