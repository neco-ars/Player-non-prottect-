# Вход через Google и синхронизация

Плейлисты, «Любимое», история, «Скрытое» и вкус для «Моей волны» хранятся в бесплатном проекте
[Supabase](https://supabase.com) — по одной строке на пользователя, видит её только он сам.
Настраивается один раз владельцем сборки (≈15 минут), дальше друзья просто нажимают
**⚙ Настройки → Войти через Google**.

Понадобятся два сайта: **Supabase** (хранилище и вход) и **Google Cloud** (кнопка «Войти через Google»).

## 1. Проект Supabase

1. Зайди на [supabase.com](https://supabase.com) → **Start your project** → войди через GitHub.
2. **New project**: имя `music-player`, придумай пароль базы (он больше не понадобится, но сохрани),
   регион **Central EU (Frankfurt)** → **Create new project**. Подожди 1–2 минуты.
3. Слева **SQL Editor** → **New query** → вставь всё из файла [`supabase/schema.sql`](../supabase/schema.sql) → **Run**.
   Должно появиться «Success. No rows returned».
4. Слева **Project Settings** (шестерёнка) → **Data API** (или **API**): скопируй **Project URL**
   (вида `https://abcd1234.supabase.co`). Затем **API Keys**: скопируй ключ **anon / public**
   (или **publishable**, начинается с `sb_publishable_` или `eyJ`). Это публичный ключ —
   его можно вшивать в приложение, данные защищены правилами из шага 3.
   Ключ **service_role / secret** не копируй и никому не давай.

## 2. Кнопка Google (Google Cloud)

1. Открой [console.cloud.google.com](https://console.cloud.google.com) → вверху выбор проекта →
   **New project** → имя `music-player` → **Create**, затем выбери его.
2. **APIs & Services → OAuth consent screen** (или **Google Auth Platform → Branding**):
   - **Get started**: App name `Music Player`, support email — твой; Audience — **External**;
     контактный email — твой → **Create**.
   - **Audience** → **Publish app** → **Confirm**. (Пока приложение в режиме «Testing», войти могут
     только добавленные вручную тестовые пользователи. Мы просим только имя и email —
     проверка Google для этого не нужна.)
3. **Clients** (или **Credentials → Create credentials → OAuth client ID**):
   - Application type: **Web application**, имя `Supabase`.
   - **Authorized redirect URIs** → **Add URI** → `https://<твой-проект>.supabase.co/auth/v1/callback`
     (адрес из шага 1.4 + `/auth/v1/callback`).
   - **Create** → скопируй **Client ID** и **Client secret**.

## 3. Включить Google в Supabase

1. Supabase → **Authentication → Sign In / Providers** → **Google** → включи.
2. Вставь **Client ID** и **Client Secret** из шага 2.3 → **Save**.
3. **Authentication → URL Configuration**:
   - **Site URL**: `https://neco-ars.github.io/Player-non-prottect-/`
   - **Redirect URLs** → **Add URL**, по одной:
     - `https://neco-ars.github.io/Player-non-prottect-/` — веб-версия
     - `io.github.necoars.musicplayer://login-callback` — Android
     - `http://localhost:*/**` — Windows (вход через браузер с возвратом в приложение)
   - **Save**.

## 4. Вшить в сборку

GitHub → репозиторий → **Settings → Secrets and variables → Actions → Variables** → **New repository variable**:

| Name | Value |
|---|---|
| `SUPABASE_URL` | Project URL из шага 1.4 |
| `SUPABASE_ANON_KEY` | ключ anon / publishable из шага 1.4 |

Затем **Actions** → верхний запуск → **Re-run all jobs** (или выпусти новую версию).
Для локальной сборки — те же два значения в `keys.json`.

## Как это работает

- Все изменения сохраняются на устройстве сразу, а в облако уходят через несколько секунд.
  Раз в 3 минуты и при запуске приложение забирает изменения с других устройств.
- При слиянии ничего не теряется: у каждого плейлиста побеждает более свежая версия, удалённый плейлист
  остаётся удалённым, история объединяется по времени прослушивания.
- Выход из аккаунта не удаляет медиатеку на устройстве.
- Бесплатный проект Supabase «засыпает», если к нему неделю никто не обращался. Если так случилось —
  зайди на supabase.com и нажми **Restore project**.
