# Прокси для веб-версии

Браузер не пускает сайт напрямую в API Звука, SoundCloud и Audiomack, поэтому веб-версия
ходит к ним через этот маленький прокси на **Cloudflare Workers** (бесплатно, 100 000 запросов в день).
Прокси пересылает только запросы к этим сервисам и только с адреса твоего сайта.
Музыка идёт напрямую, мимо прокси.

## Установка (один раз, ~5 минут)

1. Зарегистрируйся на [dash.cloudflare.com](https://dash.cloudflare.com/sign-up) (бесплатный план).
2. Слева **Workers & Pages → Create → Create Worker**.
3. Имя: `music-proxy` → **Deploy**.
4. **Edit code** → удали весь код → вставь содержимое [`worker.js`](worker.js) → **Deploy**.
5. Вернись к воркеру → **Settings → Variables and Secrets → Add**:
   - Type: `Text`, Name: `ALLOWED_ORIGIN`, Value: `https://ТВОЙ_НИК.github.io` (без слеша на конце) → **Deploy**.
6. Скопируй адрес воркера (вида `https://music-proxy.ТВОЙ_АККАУНТ.workers.dev`).
7. В репозитории на GitHub: **Settings → Secrets and variables → Actions → Variables → New repository variable**:
   - Name: `PROXY_URL`, Value: адрес из шага 6.

После следующей сборки адрес прокси будет вшит в веб-версию.

## Важно

- Через прокси проходит токен Звука тех, кто вошёл в аккаунт. Прокси его никуда не сохраняет,
  но воркер на твоём аккаунте — не давай доступ к аккаунту Cloudflare посторонним.
