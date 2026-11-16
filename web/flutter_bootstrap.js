{{flutter_js}}
{{flutter_build_config}}

// Retire only Coach's old Flutter cache worker. New releases load versioned code.
(async () => {
  if ('serviceWorker' in navigator) {
    const ownWorker = new URL('flutter_service_worker.js', document.baseURI).href;
    try {
      for (const registration of await navigator.serviceWorker.getRegistrations()) {
        if ([registration.active, registration.waiting, registration.installing]
            .some(worker => worker?.scriptURL === ownWorker)) {
          await registration.unregister();
        }
      }
    } catch (_) { /* Normal online loading remains available. */ }
  }
  _flutter.loader.load();
})();
