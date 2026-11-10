/* Shared logic of the bundled offline / error pages (no framework, no network). */
(function () {
  'use strict';
  var T = {
    en: {
      offline_t: 'You are offline', offline_p: 'The site cannot be reached. Check your internet connection. We will reload it automatically when the connection is back.',
      dns_t: 'Cannot find the server', dns_p: 'The address could not be resolved. This usually means there is no internet connection.',
      timeout_t: 'The server is not responding', timeout_p: 'The connection timed out. Try again in a moment.',
      error_t: 'The page could not be loaded', error_p: 'Something went wrong while loading the site. Try again.',
      unresponsive_t: 'The page stopped responding', unresponsive_p: 'The page was reloaded several times but is still not responding.',
      retry: 'Try again', checking: 'Checking...', still: 'Still not reachable', reason: 'Reason'
    },
    fa: {
      offline_t: 'اتصال به اینترنت برقرار نیست', offline_p: 'دسترسی به سایت ممکن نیست. اتصال اینترنت خود را بررسی کنید. با برقراری دوباره‌ی اتصال، صفحه خودکار بارگذاری می‌شود.',
      dns_t: 'سرور پیدا نشد', dns_p: 'آدرس سایت قابل تشخیص نبود. معمولاً به معنی قطع بودن اینترنت است.',
      timeout_t: 'سرور پاسخ نمی‌دهد', timeout_p: 'زمان اتصال به پایان رسید. کمی بعد دوباره تلاش کنید.',
      error_t: 'بارگذاری صفحه انجام نشد', error_p: 'هنگام بارگذاری سایت مشکلی پیش آمد. دوباره تلاش کنید.',
      unresponsive_t: 'صفحه پاسخ نمی‌دهد', unresponsive_p: 'صفحه چندین بار بارگذاری مجدد شد اما هنوز پاسخ نمی‌دهد.',
      retry: 'تلاش دوباره', checking: 'در حال بررسی...', still: 'هنوز در دسترس نیست', reason: 'دلیل'
    }
  };
  var q = new URLSearchParams(location.search);
  var lang = (q.get('lang') || navigator.language || 'en').toLowerCase().split('-')[0];
  var tr = T[lang] || T.en;
  var reason = (q.get('reason') || 'error').replace(/[^a-z-]/g, '');
  var key = { dns: 'dns', unreachable: 'offline', timeout: 'timeout', unresponsive: 'unresponsive' }[reason] || (document.body.dataset.kind === 'offline' ? 'offline' : 'error');
  document.documentElement.lang = lang;
  document.documentElement.dir = (lang === 'fa' || lang === 'ar' || lang === 'he' || lang === 'ur') ? 'rtl' : 'ltr';
  document.getElementById('title').textContent = tr[key + '_t'];
  document.getElementById('text').textContent = tr[key + '_p'];
  document.getElementById('reason').textContent = tr.reason + ': ' + reason;
  var btn = document.getElementById('retry');
  btn.textContent = tr.retry;

  function call(action) {
    var i = window.__TAURI_INTERNALS__;
    if (!i || !i.invoke) return Promise.reject(new Error('bridge unavailable'));
    return i.invoke('bridge', { request: { action: action, payload: null } });
  }
  btn.addEventListener('click', function () {
    btn.disabled = true; btn.textContent = tr.checking;
    call('network.retry').then(function (r) {
      if (!r.online) { btn.disabled = false; btn.textContent = tr.retry; document.getElementById('hint').textContent = tr.still; }
    }).catch(function () { btn.disabled = false; btn.textContent = tr.retry; });
  });
  call('app.info').then(function (i) { if (i && i.siteName) document.title = i.siteName; }).catch(function () {});
})();
