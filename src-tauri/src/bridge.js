/* Web2App bridge - injected into every page of the main window.
 * It can only reach the single Rust command `bridge`, which re-validates the
 * origin and an action allowlist on every call. Nothing else of Tauri's IPC
 * is reachable from remote content (see src-tauri/capabilities/). */
(function () {
  'use strict';
  if (window.__W2A_BOOT__) return;
  try { Object.defineProperty(window, '__W2A_BOOT__', { value: true }); } catch (e) { return; }

  var CFG = __W2A_CONFIG__;
  var internals = window.__TAURI_INTERNALS__;
  function noop() {}

  function call(action, payload) {
    if (!internals || typeof internals.invoke !== 'function') {
      return Promise.reject(new Error('Web2App bridge is not available'));
    }
    return internals.invoke('bridge', {
      request: { action: action, payload: payload === undefined ? null : payload }
    });
  }

  /* ---------- in-page splash (color + logo), first page of a session only ---------- */
  try {
    if (CFG.splash.enabled && !window.sessionStorage.getItem('__w2a_splash_done')) {
      var splash;
      var mount = function () {
        var root = document.documentElement;
        if (!root || splash) return !!splash;
        splash = document.createElement('div');
        splash.id = '__w2a_splash';
        splash.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;z-index:2147483647;' +
          'display:flex;align-items:center;justify-content:center;transition:opacity .25s;background:' + CFG.splash.color;
        if (CFG.splash.logo) {
          var img = document.createElement('img');
          img.src = CFG.splash.logo;
          img.style.cssText = 'max-width:40%;max-height:40%;';
          splash.appendChild(img);
        }
        root.appendChild(splash);
        return true;
      };
      var hide = function () {
        if (!splash) return;
        splash.style.opacity = '0';
        setTimeout(function () { if (splash && splash.parentNode) splash.parentNode.removeChild(splash); }, 300);
        try { window.sessionStorage.setItem('__w2a_splash_done', '1'); } catch (e) {}
      };
      if (!mount()) {
        var mo = new MutationObserver(function () { if (mount()) mo.disconnect(); });
        mo.observe(document, { childList: true });
      }
      window.addEventListener('load', function () { setTimeout(hide, 150); }, { once: true });
      setTimeout(hide, 8000); /* hard cap */
    }
  } catch (e) { /* splash is cosmetic */ }

  /* ---------- heartbeat used by the load / hang watchdog ---------- */
  var started = false;
  function ready() {
    if (started) return;
    started = true;
    call('page.ready').catch(noop);
    setInterval(function () { call('page.keepalive', { hidden: !!document.hidden }).catch(noop); }, 10000);
    document.addEventListener('visibilitychange', function () {
      call('page.keepalive', { hidden: !!document.hidden }).catch(noop);
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, { once: true });
  else ready();

  /* ---------- public API (only functions backed by enabled features) ---------- */
  var api = {
    version: 1,
    platform: CFG.platform,
    features: Object.freeze(Object.assign({}, CFG.features)),
    info: function () { return call('app.info'); },
    networkStatus: function () { return call('network.status'); }
  };
  if (CFG.features.externalApps) api.openExternal = function (url) { return call('app.openExternal', { url: String(url) }); };
  if (CFG.features.clipboard) api.copyText = function (text) { return call('clipboard.writeText', { text: String(text) }); };
  if (CFG.features.notifications) {
    api.notify = function (title, body, tag) {
      return call('notification.show', { title: String(title), body: body == null ? null : String(body), tag: tag == null ? null : String(tag) });
    };
  }
  try { Object.defineProperty(window, 'Web2App', { value: Object.freeze(api), enumerable: false }); } catch (e) {}

  /* ---------- Notification API shim (WebViews lack a working one on mobile) ---------- */
  if (CFG.features.notifications) {
    var perm = 'default';
    var mapPerm = function (s) { return s === 'granted' ? 'granted' : (s === 'denied' ? 'denied' : 'default'); };
    call('notification.permission').then(function (s) { perm = mapPerm(s); }).catch(noop);
    var W2ANotification = function (title, options) {
      options = options || {};
      call('notification.show', { title: String(title), body: options.body == null ? null : String(options.body), tag: options.tag == null ? null : String(options.tag) }).catch(noop);
    };
    Object.defineProperty(W2ANotification, 'permission', { get: function () { return perm; } });
    W2ANotification.requestPermission = function (cb) {
      return call('notification.request').then(function (s) {
        perm = mapPerm(s);
        if (typeof cb === 'function') cb(perm);
        return perm;
      });
    };
    W2ANotification.prototype.close = noop;
    try { Object.defineProperty(window, 'Notification', { value: W2ANotification, configurable: true, writable: true }); } catch (e) {}
  }
})();
