self.addEventListener('install', event => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', event => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', event => {
  let payload = {};
  if (event.data) {
    try {
      const parsed = event.data.json();
      if (parsed && typeof parsed === 'object') payload = parsed;
    } catch {
      payload = { body: event.data.text() };
    }
  }

  const title = typeof payload.title === 'string' ? payload.title : '筑前生徒会';
  const body = typeof payload.body === 'string' ? payload.body : '新しいお知らせがあります';
  const target = typeof payload.url === 'string' ? payload.url : './';
  event.waitUntil(self.registration.showNotification(title, {
    body,
    data: { url: target }
  }));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const scopeUrl = new URL(self.registration.scope);
  const requestedUrl = new URL(event.notification.data?.url || './', scopeUrl);
  const isAppUrl = requestedUrl.origin === scopeUrl.origin
    && requestedUrl.pathname.startsWith(scopeUrl.pathname);
  const targetUrl = isAppUrl ? requestedUrl.href : scopeUrl.href;
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clients => {
    const appClient = clients.find(client => {
      const clientUrl = new URL(client.url);
      return clientUrl.origin === scopeUrl.origin && clientUrl.pathname.startsWith(scopeUrl.pathname);
    });
    if (appClient) {
      return appClient.navigate(targetUrl).then(() => appClient.focus());
    }
    return self.clients.openWindow(targetUrl);
  }));
});
