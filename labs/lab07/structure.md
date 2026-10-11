# ЛР 7. Структура документа «Учётная запись сеанса»

## Назначение

Учётная запись сеанса связи — документ, который биллинг провайдера выгружает по каждому завершённому сеансу абонента: откуда пришёл сеанс (провайдер и сервер доступа — NAS), по какому договору, когда начался и закончился, сколько трафика прошло в каждую сторону, как он протарифицирован, какие атрибуты передало оборудование и какие события были за время сеанса. В предметной области курсовой это то, что `docs/analysis/domain.md` называет «в реальности — загрузка из биллинга»: строка `core.session` (договор, время, тариф, объём, скидка, стоимость) — разобранная часть такой записи.

Почему JSONB (D29): у разных производителей оборудования доступа (MikroTik, Cisco, Juniper, Huawei, Accel-PPP) набор атрибутов разный — ограничение скорости, пул адресов, порт, политика передаются разными ключами, а со сменой оборудования или прошивки набор меняется. Под каждый набор пришлось бы заводить колонки или таблицу «ключ — значение»; документ хранится целиком, как пришёл, а нужное разбирается запросами (`sql/05_functions.sql`, запрос 5.4 — в строку `core.session`).

Таблица: `lab7.session_record (id bigint identity PK, received_at timestamptz, doc jsonb)`; проверка `ck_session_record_doc` — документ является объектом и содержит разделы `source`, `contract`, `session`, `billing`, `attributes`, `events` (`sql/01_create.sql`). Пример — `sample_document.json` (две записи: MikroTik и Cisco).

## Ключи документа

Обязательность: «да» — ключ есть в каждой записи; «может быть null» — ключ есть, значение может отсутствовать; «нет» — ключ появляется только в части записей.

| Путь | Тип JSON | Обязательность | Описание | Пример |
|---|---|---|---|---|
| `source` | object | да | Откуда пришла запись | |
| `source.provider` | object | да | Провайдер, выгрузивший запись | |
| `source.provider.name` | string | да | Название провайдера (= `core.provider.name`) | `"ДонНет"` |
| `source.provider.city` | string | да | Город провайдера | `"Горловка"` |
| `source.nas` | object | да | Сервер доступа (NAS), обслуживший сеанс | |
| `source.nas.name` | string | да | Имя узла | `"bras01-2"` |
| `source.nas.vendor` | string | да | Производитель: MikroTik, Cisco, Juniper, Huawei, Accel-PPP | `"MikroTik"` |
| `source.nas.model` | string | да | Модель оборудования | `"CCR2004-1G-12S+2XS"` |
| `source.nas.ip` | string | да | Адрес узла в сети провайдера | `"172.16.1.2"` |
| `source.nas.location` | object | да | Где стоит узел | |
| `source.nas.location.city` | string | да | Город | `"Снежное"` |
| `source.nas.location.address` | string | да | Адрес | `"бул. Шевченко, д. 75"` |
| `contract` | object | может быть null | Договор абонента; `null` — служебный сеанс наладки узла (удаляются в 7.1) | |
| `contract.number` | string | да (если есть договор) | Номер договора (= `core.contract.contract_no`) | `"Д-2024-000050"` |
| `contract.ip` | string | да (если есть договор) | IP-адрес абонента по договору (D1) | `"10.0.10.46"` |
| `session` | object | да | Сеанс | |
| `session.acct_id` | string | да | Идентификатор сеанса на NAS (RADIUS Acct-Session-Id); уникален у провайдера | `"84AB7736"` |
| `session.user_name` | string | да | Логин подключения (PPPoE) | `"d2024000050"` |
| `session.started_at` | string (ISO 8601) | да | Начало сеанса, точность — секунда, смещение +03:00 | `"2026-10-07T11:10:35+03:00"` |
| `session.stopped_at` | string (ISO 8601) | да | Завершение сеанса | `"2026-10-07T14:35:43+03:00"` |
| `session.duration_s` | number | да | Длительность, с | `12308` |
| `session.stop_cause` | string | да | Причина завершения (RADIUS Acct-Terminate-Cause): `user_request`, `idle_timeout`, `lost_carrier`, `port_error`, `admin_reset`, `nas_reboot`, `nas_error`, `service_unavailable` | `"lost_carrier"` |
| `session.traffic` | object | да | Трафик сеанса по направлениям | |
| `session.traffic.in` | object | да | Входящий — к абоненту (загрузка) | |
| `session.traffic.in.mb` | number | да | Мегабайты | `557.173` |
| `session.traffic.in.packets` | number | да | Пакеты | `393895` |
| `session.traffic.out` | object | да | Исходящий — от абонента | |
| `session.traffic.out.mb` | number | да | Мегабайты; `in.mb + out.mb` = `core.session.volume_mb` | `106.827` |
| `session.traffic.out.packets` | number | да | Пакеты | `278409` |
| `billing` | object | да | Тарификация | |
| `billing.tariff` | object | да | Тариф (= строка `ref.tariff`) | |
| `billing.tariff.code` | string | да | Обозначение тарифа (D20) | `"Б"` |
| `billing.tariff.name` | string | да | Название | `"Бизнес-время"` |
| `billing.tariff.window` | object | может быть null | Окно времени тарифа (D2, D13); `null` — тариф назначается вручную | |
| `billing.tariff.window.from` | string | да (если есть окно) | Начало окна | `"09:00"` |
| `billing.tariff.window.to` | string | да (если есть окно) | Конец окна; `from > to` — окно через полночь | `"18:00"` |
| `billing.tariff.weekend` | boolean | может быть null | Тип дня: выходные / будни / любой (`null`) | `false` |
| `billing.price_per_mb` | number | может быть null | Стоимость 1 Мб по договору; `null` у служебных сеансов | `0.1305` |
| `billing.discount_pct` | number | да | Скидка тарифа, % (снимок, D3) | `0.00` |
| `billing.cost` | number | да | Стоимость сеанса (снимок, D3) | `86.65` |
| `billing.invoice` | string | нет | Номер счёта, в который вошёл сеанс; добавляется при выставлении счёта (6.2) | `"СЧ-2026-09/Д-2025-007092"` |
| `attributes` | object | да (может быть пустым) | Атрибуты, переданные NAS; набор зависит от производителя — таблица ниже | |
| `events` | array of object | да | Журнал событий сеанса по времени | |
| `events[].at` | string (ISO 8601) | да | Время события | `"2026-10-07T12:10:35+03:00"` |
| `events[].type` | string | да | `start`, `interim` (промежуточное обновление, раз в час), `coa` (смена скорости по команде, 6.4), `stop` | `"interim"` |
| `events[].in_mb`, `events[].out_mb` | number | у `interim` | Накопленный трафик с начала сеанса | `162.969` |
| `events[].cause` | string | у `stop` | Причина завершения | `"lost_carrier"` |
| `events[].rate_mbps` | number | у `coa` | Новая скорость, Мбит/с | `500` |
| `events[].resent` | boolean | нет | Обновление переслано NAS повторно (6.5) | `true` |
| `review` | object | нет | Отметка о проверке записи по жалобе абонента (6.6): `by`, `at`, `result` | |

### Атрибуты по производителям (`attributes`)

| Производитель | Атрибуты | Признак должника |
|---|---|---|
| MikroTik | `rate_limit` (строка «100M/100M»), `framed_pool`, `calling_station_id` | `address_list = "debtors"` |
| Cisco | `av_pairs` (массив строк), `nas_port_id`, `calling_station_id` | `redirect_url` |
| Juniper | `service_activate`, `ingress_policy`, `primary_dns`, `calling_station_id` | `redirect_url` |
| Huawei | `input_peak_rate_kbps`, `output_peak_rate_kbps` (числа), `domain_name` (бывает null), `calling_station_id` | `redirect_url` |
| Accel-PPP | `nas_port_id`, `framed_protocol`, `downstream_limit_kbps`, `upstream_limit_kbps`, `framed_pool` (бывает null), `calling_station_id` | `redirect_url` |
| все | `class` — служебная метка сервера авторизации (у провайдеров с чётным кодом) | |

`calling_station_id` — MAC-адрес оборудования абонента: персональные сведения, в записях старше года удаляется (6.8). Пустые (`null`) атрибуты удаляются `jsonb_strip_nulls` (6.9). Фактическое распределение ключей по производителям — `explain/5.2_vendor_keys.txt`.

## Глубина вложенности

Глубина — 4 уровня объектов от корня документа (массив `events` — 3 уровня: `events` → элемент → `in_mb`):

| Путь | Уровни |
|---|---|
| `source.nas.location.city` | `source` → `nas` → `location` → `city` |
| `session.traffic.in.mb` | `session` → `traffic` → `in` → `mb` |
| `billing.tariff.window.from` | `billing` → `tariff` → `window` → `from` (у тарифов с окном времени) |

Проверка на данных — последний запрос `sql/02_generate.sql` (`explain/02_generate.txt`): пути четвёртого уровня есть у всех 101 625 сгенерированных записей (`window.from` — у записей тарифов с окном).

## Соответствие строке `core.session`

| Колонка `core.session` | Откуда в документе |
|---|---|
| `contract_id` | `core.contract.id` по `source.provider.name` + `contract.number` |
| `started_at` | `session.started_at` |
| `tariff_id` | `ref.tariff.id` по `billing.tariff.code` |
| `volume_mb` | `session.traffic.in.mb + session.traffic.out.mb` (запись без трафика не разбирается: домен `d_mb` требует > 0) |
| `discount_pct` | `billing.discount_pct` |
| `cost` | `billing.cost` |

Разбор — `jsonb_populate_record(NULL::core.session, …)`, запросы 5.4 и 5.5; сверка 5.5: все 100 025 записей с договором и трафиком совпали с сеансами курсовой.

## Соглашения

- Ключи — английские, `snake_case`, как имена в схеме курсовой; значения справочников (тарифы, города, провайдеры) — как в `ref`/`core`.
- Время — строка ISO 8601 с точностью до секунды и смещением `+03:00` (часовой пояс предметной области, D19; в Москве нет перехода на летнее время с 2014 года). Одинаковое смещение у всех записей делает побайтовое сравнение строк (`COLLATE "C"`) равным сравнению времени — на этом построен индекс по времени начала (`sql/08_indexes.sql`, индекс 4).
- Порядок ключей в выводе `jsonb` — не порядок ввода: `jsonb` хранит ключи объекта отсортированными (короче — раньше, при равной длине — побайтово), дубли ключей не хранит. Порядок в `sample_document.json` — как в таблице выше (форматирует `run_lab7.py`).
- Средний размер записи — 1,4 КБ, наибольший — 1,8 КБ (`explain/02_generate.txt`): меньше порога TOAST (~2 КБ), записи хранятся в строке таблицы без сжатия.
