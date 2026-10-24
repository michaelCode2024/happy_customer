(() => {
  'use strict';
  if (window.TongyuSupport) return;

  const CONFIG_URL = '/website/support-config.json';
  const WIDGET_URL = '/widget.js';
  const LOGO_URL = '/website/logo.svg';
  // 官网用页面右下角自己的入口，不显示组件自带的启动按钮，面板贴底并恢复 640 高。
  const PANEL_CSS =
    '@media (min-width: 481px){.rd-panel:not(.is-embedded){bottom:20px;height:min(640px,calc(100dvh - 40px))}}';
  const HEADSET =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 13v-2a8 8 0 0 1 16 0v2M4 12H3v7h4v-7H4Zm16 0h1v7h-4v-7h3ZM20 19c0 3-4 3-8 3"/></svg>';
  const ENTRIES = ['business', 'support'];

  let loading;
  let warmed = false;
  let current;
  let opener;
  let dock;
  let toastTimer;

  async function loadConfig() {
    const response = await fetch(CONFIG_URL, { cache: 'no-store' });
    if (!response.ok) throw new Error('config unavailable');
    return response.json();
  }

  function loadWidget() {
    if (window.TongYu) return Promise.resolve(window.TongYu);
    return new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = WIDGET_URL;
      script.async = true;
      script.onload = () =>
        window.TongYu
          ? resolve(window.TongYu)
          : reject(new Error('widget unavailable'));
      script.onerror = () => {
        script.remove();
        reject(new Error('widget unavailable'));
      };
      document.head.append(script);
    });
  }

  function prepare() {
    if (!loading) {
      loading = Promise.all([loadConfig(), loadWidget()]).catch((error) => {
        loading = undefined;
        throw error;
      });
    }
    return loading;
  }

  function entryOptions(settings, name) {
    const entries = settings.entries || {};
    const entry = entries[name] || {};
    // 商务收件箱还没建好时先进技术支持收件箱；会话主题仍按入口区分，客服能看出来源。
    const inboxKey = entry.inboxKey || entries.support?.inboxKey;
    if (!inboxKey) return undefined;
    const options = {
      endpoint: location.origin,
      inboxKey,
      title: entry.title,
      subtitle: entry.subtitle,
      placeholder: entry.placeholder,
      subject: entry.subject,
      displayName: '官网咨询访客',
      referrer: location.origin + location.pathname,
      attributes: { supportSource: 'WEBSITE', supportEntry: name },
      logoUrl: LOGO_URL,
      avatarUrl: LOGO_URL,
      launcher: 'none',
      source: 'WEB',
      customCss: PANEL_CSS,
      onEvent: handleEvent,
    };
    // 组件用展开合并默认值，未配置的字段不能以 undefined 覆盖默认值。
    Object.keys(options).forEach((key) => {
      if (options[key] === undefined || options[key] === '') delete options[key];
    });
    return options;
  }

  async function open(name, prefill = '') {
    if (!ENTRIES.includes(name)) return;
    const button = dock?.querySelector(`[data-open="${name}"]`);
    button?.setAttribute('aria-busy', 'true');
    try {
      const [settings, api] = await prepare();
      const options = settings.enabled ? entryOptions(settings, name) : undefined;
      if (!options) throw new Error('entry unavailable');
      let widget = api.widget;
      if (!widget?.isConnected || current !== name) {
        widget = api.mount(options);
        current = name;
      }
      widget.open();
      if (prefill) widget.prefill(prefill);
    } catch {
      toast('在线咨询暂时打不开，请稍后再试。');
    } finally {
      button?.removeAttribute('aria-busy');
    }
  }

  function handleEvent(event) {
    if (event.type === 'open') {
      document.documentElement.classList.add('tongyu-chat-open');
      setBadge(0);
    } else if (event.type === 'close') {
      document.documentElement.classList.remove('tongyu-chat-open');
      if (opener?.isConnected) opener.focus();
    } else if (event.type === 'unread') {
      setBadge(Number(event.data?.count) || 0);
    }
  }

  function setBadge(count) {
    if (!dock) return;
    dock.querySelectorAll('.dock-badge').forEach((badge) => badge.remove());
    const button = current && dock.querySelector(`[data-open="${current}"]`);
    if (!button || count <= 0) return;
    const badge = document.createElement('span');
    badge.className = 'dock-badge';
    badge.textContent = count > 99 ? '99+' : String(count);
    badge.setAttribute('aria-label', `${count} 条未读消息`);
    button.append(badge);
  }

  function toast(text) {
    let node = document.querySelector('.tongyu-toast');
    if (!node) {
      node = document.createElement('div');
      node.className = 'tongyu-toast';
      node.setAttribute('role', 'status');
      document.body.append(node);
    }
    node.textContent = text;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => node.remove(), 4000);
  }

  function renderDock() {
    if (dock || !document.body.hasAttribute('data-tongyu-dock')) return;
    dock = document.createElement('div');
    dock.className = 'tongyu-dock';
    dock.setAttribute('role', 'group');
    dock.setAttribute('aria-label', '在线咨询');
    dock.innerHTML =
      '<button type="button" class="dock-ai" data-open="business"><span class="dock-spark" aria-hidden="true"></span>商务咨询</button>' +
      `<button type="button" class="dock-support" data-open="support">${HEADSET}技术支持</button>`;
    document.body.append(dock);
  }

  // 鼠标移到或聚焦入口时先拉配置和组件脚本，点开时少等一下；组件到打开时才建访客会话。
  function warm(event) {
    if (warmed || !event.target.closest?.('[data-open]')) return;
    warmed = true;
    prepare().catch(() => {});
  }

  document.addEventListener('click', (event) => {
    const trigger = event.target.closest?.('[data-open]');
    if (!trigger || !ENTRIES.includes(trigger.dataset.open)) return;
    event.preventDefault();
    opener = trigger;
    void open(trigger.dataset.open, trigger.dataset.prefill || '');
  });
  document.addEventListener('pointerover', warm, { passive: true });
  document.addEventListener('focusin', warm);

  window.TongyuSupport = { open };
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', renderDock, { once: true });
  else renderDock();
})();
