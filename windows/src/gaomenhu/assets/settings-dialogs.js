'use strict';

(() => {
  const overlay = $('dialogOverlay');
  const dialog = $('dialog');
  let pendingFocus = 0;

  function section(title, description) {
    const card = document.createElement('section');
    card.className = 'editor-section';
    const heading = document.createElement('h3');
    heading.textContent = title;
    card.append(heading);
    if (description) {
      const hint = document.createElement('p');
      hint.className = 'form-note';
      hint.textContent = description;
      card.append(hint);
    }
    return card;
  }

  function prepareSiteEditor(form) {
    const identity = section('网站资料');
    const fields = form.querySelector('.two-col');
    const aliases = $('siteAliases').closest('label');
    const row = document.createElement('div');
    row.className = 'editor-identity';
    const mark = form.querySelector('.icon-edit');
    $('resetIcon').removeAttribute('style');
    $('siteURL').inputMode = 'url';
    $('siteURL').spellcheck = false;
    aliases.querySelector('span').textContent = '搜索别名（可选）';
    row.append(fields, mark);
    fields.append(aliases);
    identity.append(row);

    const browsers = section('打开方式');
    const allowed = $('browserOptions').closest('.field');
    allowed.querySelector('.field-label').textContent = '允许使用的浏览器';
    const defaults = $('defaultBrowser').closest('label');
    defaults.querySelector('.field-label').textContent = '默认浏览器';
    browsers.append(allowed, defaults, $('profileFields'));

    const accounts = section('关联账号');
    const heading = form.querySelector('.section-title');
    const description = form.querySelector('.form-note');
    const actions = $('addAccount');
    const bar = document.createElement('div');
    bar.className = 'editor-section-heading';
    bar.append(accounts.querySelector('h3'), actions);
    accounts.append(bar, $('accounts'), description);
    description.textContent = 'Chrome 和 Edge 可自动填充。密码由 Windows 凭据保护，登录仍由你确认。';
    heading.remove();
    actions.addEventListener('click', () => requestAnimationFrame(() => {
      form.querySelector('#accounts .account-card:last-child input[data-field="label"]')?.focus();
    }));

    form.prepend(identity, browsers, accounts);
    dialog.classList.add('site-editor-dialog');
    const title = dialog.querySelector('.dialog-head h2');
    if (title.textContent !== '编辑网站') title.textContent = '添加网站';
    dialog.querySelector('.dialog-head .description')?.remove();
  }

  function wrapContent(container) {
    const footer = container.querySelector(':scope > .dialog-actions');
    const error = container.querySelector(':scope > .form-error');
    const header = container.querySelector(':scope > .dialog-head');
    const content = document.createElement('div');
    content.className = 'windows-dialog-content';
    for (const node of [...container.childNodes]) {
      if (node !== footer && node !== header && (node !== error || !footer)) content.append(node);
    }
    container.append(content);
    if (footer) {
      if (error) footer.prepend(error);
      container.append(footer);
    }
  }

  openDialog = function openWindowsDialog(html, small = false) {
    if (overlay.hidden || !lastFocus?.isConnected) lastFocus = document.activeElement;
    dialog.className = 'dialog windows-dialog' + (small ? ' small' : '');
    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    dialog.removeAttribute('aria-labelledby');
    dialog.setAttribute('tabindex', '-1');
    dialog.innerHTML = html;
    overlay.hidden = false;
    dialog.querySelectorAll('[data-close]').forEach(button => { button.onclick = closeDialog; });

    const title = dialog.querySelector('.dialog-head h2, .preferences-header h2');
    if (title) {
      title.id ||= 'windows-dialog-title';
      dialog.setAttribute('aria-labelledby', title.id);
    }
    const form = dialog.querySelector(':scope > form');
    if (form?.id === 'siteForm') prepareSiteEditor(form);
    if (!dialog.querySelector('.preferences-layout')) wrapContent(form || dialog);
    dialog.querySelectorAll('.form-error').forEach(error => error.setAttribute('role', 'alert'));

    const operation = ++pendingFocus;
    requestAnimationFrame(() => {
      if (operation !== pendingFocus || overlay.hidden) return;
      const field = dialog.querySelector('[role="tab"][aria-selected="true"], input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]):not(:disabled), select:not(:disabled), textarea:not(:disabled)');
      const cancel = dialog.querySelector('.dialog-actions [data-close]');
      (field || cancel || dialog.querySelector('button:not(:disabled)') || dialog).focus({preventScroll: true});
    });
  };

  const sourceAccounts = renderAccounts;
  renderAccounts = function renderWindowsAccounts() {
    sourceAccounts();
    for (const field of document.querySelectorAll('#accounts .account-fields input')) {
      const label = document.createElement('label');
      label.className = field.classList.contains('wide') ? 'wide' : '';
      const title = document.createElement('span');
      title.className = 'field-label';
      title.textContent = field.getAttribute('aria-label');
      field.before(label);
      label.append(title, field);
      if (field.dataset.field === 'label') field.placeholder = '例如工作账号';
      if (field.dataset.field === 'username') field.placeholder = 'name@example.com';
      if (field.dataset.field === 'hosts') field.placeholder = 'auth.example.com';
    }
  };

  const sourceBrowsers = renderBrowserOptions;
  renderBrowserOptions = function renderWindowsBrowsers() {
    const focused = document.activeElement?.closest('.browser-choice')?.dataset.browserChoice;
    sourceBrowsers();
    document.querySelectorAll('#browserOptions .browser-choice').forEach((label, index) => {
      const id = S.browsers[index].id;
      label.dataset.browserChoice = id;
      if (focused === id) (label.querySelector('input:not(:disabled)') || $('defaultBrowser')).focus({preventScroll: true});
    });
    document.querySelectorAll('#profileFields .profile-field').forEach(field => {
      const selector = field.querySelector('select');
      selector.id = 'profile-' + selector.dataset.browser;
      field.querySelector('label').htmlFor = selector.id;
    });
  };

  const sourceEditorIcon = renderEditorIcon;
  renderEditorIcon = function renderWindowsEditorIcon() {
    const focused = document.activeElement?.closest('#palette .color-dot')?.getAttribute('aria-label');
    sourceEditorIcon();
    for (const button of $('palette').children) {
      button.setAttribute('aria-pressed', String(button.classList.contains('active')));
      if (focused === button.getAttribute('aria-label')) button.focus({preventScroll: true});
    }
  };

  document.addEventListener('keydown', event => {
    const crop = $('cropOverlay');
    const folder = $('folderOverlay');
    const active = !crop.hidden && crop.querySelector('.dialog') ||
      !overlay.hidden && dialog || !folder.hidden && folder.querySelector('.folder-panel');
    if (!active) return;
    if (event.key === 'Escape' && event.isComposing) {
      event.stopImmediatePropagation();
      return;
    }
    if (event.key !== 'Tab' || active.getAttribute('role') === 'main') return;
    const focusable = [...active.querySelectorAll('button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [href], [tabindex]')]
      .filter(element => element.tabIndex >= 0 && element.getClientRects().length);
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable.at(-1);
    if (!active.contains(document.activeElement) || document.activeElement === (event.shiftKey ? first : last)) {
      event.preventDefault();
      (event.shiftKey ? last : first).focus();
    }
  }, true);
})();
