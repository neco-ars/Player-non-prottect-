// Прокси для веб-версии Music Player (Cloudflare Workers).
//
// Браузер не даёт сайту напрямую обращаться к API Звука, SoundCloud и других площадок (CORS).
// Этот воркер пересылает ТОЛЬКО поисковые/служебные запросы к этим двум сервисам
// и ТОЛЬКО с адреса твоего сайта. Сама музыка идёт напрямую, мимо прокси.
//
// Переменная окружения ALLOWED_ORIGIN — адрес сайта, например https://nick.github.io
// (без пути и без слеша на конце). Если не задана — прокси отвечает всем (не рекомендуется).

const ALLOWED_HOSTS = [
  /^soundcloud\.com$/,
  /^api-v2\.soundcloud\.com$/,
  /^a-v2\.sndcdn\.com$/, // скрипты сайта, оттуда берётся client_id
  /^api\.audiomack\.com$/,
  /^zvuk\.com$/, // Звук: гостевой токен и GraphQL API
  /^api\.genius\.com$/, // Genius: ссылка на страницу текста
  /^api\.deezer\.com$/, // Deezer: похожие исполнители и радио для рекомендаций (только данные, без музыки)
];

// Какие заголовки клиента пересылаем дальше.
const FORWARD_HEADERS = ['authorization', 'x-auth-token', 'accept', 'accept-language', 'content-type'];

const BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const allowed = (env.ALLOWED_ORIGIN || '').trim();
    if (allowed && origin !== allowed) {
      return new Response('Forbidden origin', { status: 403 });
    }

    const cors = {
      'Access-Control-Allow-Origin': allowed || '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, X-Auth-Token, Accept, Content-Type',
      // ничего не кэшируем: ответы зависят от токенов пользователя
      'Access-Control-Max-Age': '86400',
      Vary: 'Origin',
    };

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (request.method !== 'GET' && request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405, headers: cors });
    }

    const raw = new URL(request.url).searchParams.get('url');
    let target;
    try {
      target = new URL(raw);
    } catch {
      return new Response('Bad url', { status: 400, headers: cors });
    }
    if (target.protocol !== 'https:' || !ALLOWED_HOSTS.some((re) => re.test(target.hostname))) {
      return new Response('Host not allowed', { status: 403, headers: cors });
    }

    const headers = new Headers();
    for (const h of FORWARD_HEADERS) {
      const v = request.headers.get(h);
      if (v) headers.set(h, v);
    }
    headers.set('User-Agent', BROWSER_UA);
    if (target.hostname === 'zvuk.com') {
      headers.set('Referer', 'https://zvuk.com/');
      headers.set('Origin', 'https://zvuk.com');
    }

    const upstream = await fetch(target.toString(), {
      method: request.method,
      headers,
      body: request.method === 'POST' ? await request.arrayBuffer() : undefined,
      redirect: 'follow',
    });
    const response = new Response(upstream.body, upstream);
    for (const [k, v] of Object.entries(cors)) response.headers.set(k, v);
    response.headers.delete('set-cookie');
    return response;
  },
};
