(async function () {
  const button = document.querySelector('#android-download');
  try {
    const response = await fetch('/downloads/release.json', { cache: 'no-store' });
    if (!response.ok) throw new Error('unavailable');
    const release = await response.json();
    const apk = new URL(release.android.url, location.origin);
    if (
      apk.origin !== location.origin ||
      !apk.pathname.startsWith('/downloads/') ||
      !apk.pathname.endsWith('.apk')
    )
      throw new Error('invalid');
    button.href = apk.href;
    button.removeAttribute('aria-disabled');
    button.textContent = '下载安卓安装包';
    const build = release.android.buildNumber
      ? ` · build ${release.android.buildNumber}`
      : '';
    document.querySelector('#android-info').textContent =
      `版本 ${release.android.version}${build} · 更新于 ${release.android.updatedAt}`;
    const notes = Array.isArray(release.android.notes)
      ? release.android.notes.filter(Boolean)
      : [];
    const status = [];
    if (release.android.force || release.android.minBuildNumber)
      status.push('客户端会提示必更');
    if (notes.length) status.push('更新说明：' + notes.join('；'));
    if (release.android.sha256)
      status.push('安装包校验 SHA-256：' + release.android.sha256);
    if (status.length)
      document.querySelector('#android-status').textContent = status.join(' · ');
  } catch (_) {
    button.textContent = '安装包准备中';
    document.querySelector('#android-info').textContent =
      '安装包尚未发布，请先使用网页版';
    document.querySelector('#android-status').innerHTML =
      '<a href="/console/?surface=agent">打开网页版工作台 →</a>';
  }
})();

// 苹果：步骤上方固定展示可复制的工作台地址（对齐彩站落地页地址卡）。
(function () {
  const installHref = new URL(
    '/console/?surface=agent&install=1',
    location.origin
  ).href;
  let hostLabel = location.host;
  try {
    hostLabel = new URL(installHref).host;
  } catch (_) {}

  const host = document.getElementById('apple-url-host');
  const copyBtn = document.getElementById('apple-url-copy');
  const openLink = document.getElementById('pwa-install');
  const full = document.getElementById('apple-url-full');
  if (host) {
    host.textContent = hostLabel;
    host.title = installHref;
  }
  if (openLink) openLink.href = installHref;

  async function copyAddress(button) {
    if (!button) return;
    try {
      await navigator.clipboard.writeText(installHref);
      button.textContent = '已复制';
      window.setTimeout(() => {
        button.textContent = '复制';
      }, 2000);
    } catch (_) {
      if (full) {
        full.hidden = false;
        full.textContent = installHref;
      }
      button.textContent = '长按复制';
    }
  }

  if (copyBtn) {
    copyBtn.addEventListener('click', () => copyAddress(copyBtn));
  }

  // 弹层指引保留；内嵌浏览器时强调复制到 Safari。
  if (!openLink) return;
  openLink.addEventListener('click', (event) => {
    const ios =
      /iPad|iPhone|iPod/.test(navigator.userAgent) ||
      (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    const embedded =
      /MicroMessenger|QQ\/|FBAN|FBAV|Instagram|Line\//i.test(
        navigator.userAgent
      );
    const standalone =
      matchMedia('(display-mode: standalone)').matches ||
      navigator.standalone === true;
    // 真机 Safari 已可直接打开；其它场景仍用弹层讲清步骤，并带上可复制地址。
    if (standalone || (ios && !embedded)) return;
    event.preventDefault();
    const dialog = document.createElement('dialog');
    dialog.className = 'pwa-install-dialog';
    const heading = document.createElement('h2');
    heading.textContent = 'iPhone 怎么使用通语？';
    const intro = document.createElement('p');
    intro.textContent = embedded
      ? '当前是应用内浏览器。请复制下方地址，粘贴到 Safari 打开后再添加。'
      : '请用 iPhone 的 Safari 打开工作台地址，再添加到主屏幕。';
    dialog.append(heading, intro);

    const card = document.createElement('div');
    card.className = 'apple-url-card dialog-url-card';
    card.innerHTML =
      '<div class="apple-url-label">通语工作台地址</div>' +
      '<div class="apple-url-row">' +
      '<p class="apple-url-host"></p>' +
      '<button type="button" class="apple-url-copy">复制</button>' +
      '</div>' +
      '<p class="apple-url-full" hidden></p>';
    const dialogHost = card.querySelector('.apple-url-host');
    dialogHost.textContent = hostLabel;
    dialogHost.title = installHref;
    const dialogCopy = card.querySelector('.apple-url-copy');
    const dialogFull = card.querySelector('.apple-url-full');
    dialogCopy.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(installHref);
        dialogCopy.textContent = '已复制';
        window.setTimeout(() => {
          dialogCopy.textContent = '复制';
        }, 2000);
      } catch (_) {
        dialogFull.hidden = false;
        dialogFull.textContent = installHref;
        dialogCopy.textContent = '长按复制';
      }
    });
    dialog.append(card);

    if (!ios && !standalone) {
      const qr = document.createElement('img');
      qr.src = '/website/download-qr.svg';
      qr.alt = '使用 iPhone 相机扫码打开使用指引';
      qr.className = 'apple-guide-qr';
      qr.width = 144;
      qr.height = 144;
      dialog.append(qr);
    }

    const steps = document.createElement('ol');
    for (const line of [
      '在 Safari 中打开上方工作台地址。',
      '点击分享按钮（方框向上箭头），向下找到「添加到主屏幕」。',
      '如有「作为 Web App 打开」，保持开启，再点右上角「添加」。',
      '回到手机桌面，点击「通语」图标，使用企业账号登录。',
    ]) {
      const item = document.createElement('li');
      item.textContent = line;
      steps.append(item);
    }
    const note = document.createElement('p');
    note.className = 'pwa-install-note';
    note.textContent = '已经添加过？直接从桌面打开通语，不用重复操作。';
    const actions = document.createElement('div');
    actions.className = 'pwa-install-actions';
    const close = document.createElement('button');
    close.type = 'button';
    close.textContent = '知道了';
    close.onclick = () => dialog.close();
    if (!embedded) {
      const next = document.createElement('a');
      next.className = 'button apple-button';
      next.href = installHref;
      next.textContent = '打开通语工作台';
      actions.append(next);
    }
    actions.append(close);
    dialog.append(steps, note, actions);
    document.body.append(dialog);
    dialog.addEventListener('close', () => dialog.remove(), { once: true });
    dialog.showModal();
  });
})();
