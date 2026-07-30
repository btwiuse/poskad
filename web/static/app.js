(() => {
  const form = document.querySelector('#generator-form');
  const button = document.querySelector('#generate-button');
  const toast = document.querySelector('#toast');
  const modal = document.querySelector('#image-modal');
  const modalImage = document.querySelector('#modal-image');
  const download = document.querySelector('#modal-download');
  const source = document.querySelector('#modal-source');
  const previousButton = document.querySelector('[data-modal-prev]');
  const nextButton = document.querySelector('[data-modal-next]');
  const gallery = document.querySelector('#gallery');
  const themeToggle = document.querySelector('#theme-toggle');
  const themeInput = document.querySelector('#card-theme');
  let busy = false;
  let toastTimer;
  let currentOpener = null;
  const uuidV7Pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

  function applyTheme(theme) {
    const isLight = theme === 'light';
    document.documentElement.dataset.theme = isLight ? 'light' : 'dark';
    themeInput.value = isLight ? 'light' : 'dark';
    themeToggle.setAttribute('aria-pressed', String(isLight));
    themeToggle.setAttribute('aria-label', isLight ? '切换深色主题' : '切换浅色主题');
    themeToggle.innerHTML = isLight
      ? '<span aria-hidden="true">◐</span><span class="theme-toggle-label">Dark</span>'
      : '<span aria-hidden="true">☼</span><span class="theme-toggle-label">Light</span>';
    document.querySelector('meta[name="theme-color"]').content = isLight ? '#f7f9f9' : '#09090b';
  }

  const storedTheme = localStorage.getItem('poskad-theme');
  applyTheme(storedTheme === 'light' || storedTheme === 'dark'
    ? storedTheme
    : (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'));
  themeToggle.addEventListener('click', () => {
    const theme = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    localStorage.setItem('poskad-theme', theme);
    applyTheme(theme);
  });

  function notify(message) {
    clearTimeout(toastTimer);
    toast.textContent = message;
    if (typeof toast.showPopover === 'function') {
      if (toast.matches(':popover-open')) toast.hidePopover();
      toast.showPopover();
    } else {
      toast.classList.add('visible');
    }
    toastTimer = setTimeout(() => {
      if (typeof toast.hidePopover === 'function' && toast.matches(':popover-open')) {
        toast.hidePopover();
      }
      toast.classList.remove('visible');
    }, 2600);
  }

  function setBusy(next) {
    busy = next;
    button.disabled = next;
    button.innerHTML = next ? '正在生成…' : '生成图片 <span aria-hidden="true">↗</span>';
  }

  form.addEventListener('keydown', (event) => {
    if (busy && event.key === 'Enter') {
      event.preventDefault();
      notify('图片仍在生成，请稍候。');
    }
  });

  form.addEventListener('submit', (event) => {
    if (busy) {
      event.preventDefault();
      notify('当前已有生成任务，请稍候。');
    }
  });

  // A Web Share Target redirects here with the received URL prefilled.
  // Submit it through the same guarded htmx flow as a manually pasted link.
  if (form.querySelector('[data-share-url]')) {
    const cleanURL = new URL(location.href);
    cleanURL.searchParams.delete('share');
    history.replaceState(null, '', `${cleanURL.pathname}${cleanURL.search}${cleanURL.hash}`);
    requestAnimationFrame(() => form.requestSubmit());
  }

  document.body.addEventListener('htmx:beforeRequest', (event) => {
    if (event.detail.elt === form) {
      if (busy) {
        event.preventDefault();
        notify('当前已有生成任务，请稍候。');
        return;
      }
      setBusy(true);
      form.querySelector('#url').value = '';
      notify('开始生成，日志会在下方持续更新。');
    }
  });

  document.body.addEventListener('htmx:afterSwap', () => {
    const panel = document.querySelector('#job-panel');
    const status = panel?.dataset.jobStatus;
    if (status === 'succeeded') {
      setBusy(false);
      notify('图片已生成，并已置顶到历史中。');
    } else if (status === 'failed') {
      setBusy(false);
      notify('生成失败，请检查下方日志。');
    }
    scheduleMasonry();
  });

  document.body.addEventListener('htmx:oobAfterSwap', scheduleMasonry);
  document.body.addEventListener('htmx:afterSettle', scheduleMasonry);
  document.addEventListener('load', (event) => {
    if (event.target.matches?.('#gallery img')) scheduleMasonry();
  }, true);

  document.addEventListener('click', async (event) => {
    const opener = event.target.closest('[data-modal-open]');
    if (opener) {
      openModal(opener);
      return;
    }
    if (event.target.closest('[data-modal-close]')) {
      modal.close();
      return;
    }
    if (event.target.closest('[data-modal-prev]')) {
      navigateModal(-1);
      return;
    }
    if (event.target.closest('[data-modal-next]')) {
      navigateModal(1);
      return;
    }
    if (event.target.closest('[data-copy-image]')) {
      await copyCurrentImage();
    }
  });

  async function copyCurrentImage() {
    try {
      const response = await fetch(modalImage.src);
      const blob = await response.blob();
      await navigator.clipboard.write([new ClipboardItem({ [blob.type]: blob })]);
      notify('图片已复制到剪贴板。');
    } catch (_) {
      try {
        await navigator.clipboard.writeText(modalImage.src);
        notify('浏览器不支持复制图片，已复制图片链接。');
      } catch (_) {
        notify('浏览器未授予剪贴板权限，请使用下载按钮。');
      }
    }
  }

  function openModal(opener, syncHash = true) {
    currentOpener = opener;
    modalImage.src = opener.dataset.image;
    download.href = opener.dataset.image;
    source.href = opener.dataset.source;
    if (syncHash && opener.dataset.id) {
      history.replaceState(null, '', `${location.pathname}${location.search}#${opener.dataset.id}`);
    }
    updateModalNavigation();
    if (!modal.open) modal.showModal();
  }

  function modalOpeners() {
    return [...document.querySelectorAll('#gallery [data-modal-open]')];
  }

  function updateModalNavigation() {
    const openers = modalOpeners();
    const index = openers.indexOf(currentOpener);
    previousButton.disabled = index <= 0;
    nextButton.disabled = index < 0 || index >= openers.length - 1;
  }

  function navigateModal(direction) {
    const openers = modalOpeners();
    const index = openers.indexOf(currentOpener);
    const destination = index + direction;
    if (index < 0 || destination < 0 || destination >= openers.length) return;
    openModal(openers[destination]);
  }

  document.addEventListener('keydown', (event) => {
    if (!modal.open || event.metaKey || event.ctrlKey || event.altKey) return;
    if (event.key === 'ArrowLeft' || event.key === 'k') {
      event.preventDefault();
      navigateModal(-1);
    } else if (event.key === 'ArrowRight' || event.key === 'j') {
      event.preventDefault();
      navigateModal(1);
    } else if (event.key === 'c') {
      event.preventDefault();
      copyCurrentImage();
    } else if (event.key === 'd') {
      event.preventDefault();
      download.click();
    } else if (event.key === 'o') {
      event.preventDefault();
      source.click();
    } else if (event.key === 'g') {
      event.preventDefault();
      const first = modalOpeners()[0];
      if (first) openModal(first);
    } else if (event.key === 'G') {
      event.preventDefault();
      const openers = modalOpeners();
      const last = openers[openers.length - 1];
      if (last) openModal(last);
    }
  });

  modal.addEventListener('click', (event) => {
    if (event.target === modal) modal.close();
  });

  modal.addEventListener('close', () => {
    currentOpener = null;
    if (location.hash) history.replaceState(null, '', `${location.pathname}${location.search}`);
  });

  async function openFromHash() {
    const id = location.hash.slice(1).toLowerCase();
    if (!uuidV7Pattern.test(id)) return;
    const opener = document.querySelector(`#gallery [data-id="${id}"]`);
    if (opener) {
      openModal(opener, false);
      return;
    }
    try {
      const response = await fetch(`/items/${id}`);
      if (!response.ok) return;
      const item = await response.json();
      openModal({ dataset: { id: item.id, image: item.image_url, source: item.url } }, false);
    } catch (_) {
      notify('未找到该图片。');
    }
  }

  window.addEventListener('hashchange', openFromHash);
  openFromHash();

  function layoutMasonry() {
    if (!gallery) return;
    const styles = getComputedStyle(gallery);
    const row = parseFloat(styles.gridAutoRows) || 8;
    const gap = parseFloat(styles.rowGap) || 16;
    const cards = [...gallery.querySelectorAll('.card')];

    // OOB 插入会改变 DOM 顺序。先清除旧跨度，确保 Grid 按新顺序从左上重新放置。
    cards.forEach((card) => {
      card.style.gridRowEnd = '';
    });
    void gallery.offsetHeight;

    cards.forEach((card) => {
      const span = Math.max(1, Math.ceil((card.getBoundingClientRect().height + gap) / (row + gap)));
      card.style.gridRowEnd = `span ${span}`;
    });
  }

  function scheduleMasonry() {
    requestAnimationFrame(() => {
      layoutMasonry();
      requestAnimationFrame(layoutMasonry);
    });
  }

  const resizeObserver = new ResizeObserver(() => requestAnimationFrame(layoutMasonry));
  resizeObserver.observe(gallery);
  window.addEventListener('load', scheduleMasonry);
  window.addEventListener('resize', scheduleMasonry);
})();
