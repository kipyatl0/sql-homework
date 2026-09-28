# Аудит производительности PostgreSQL

Полигон для домашки: PostgreSQL 18 с таблицами `orders` и `order_items`, скрипт с проблемой N+1 и руководство по стратегии масштабирования.

## Что уже готово, а что за тобой

| Файл | Состояние |
|---|---|
| `db_audit/schema.sql` | готов: DDL и генерация данных (пункт 1) |
| `db_audit/queries.sql` | твой: 4 запроса с `EXPLAIN ANALYZE` до индексов |
| `db_audit/indexes.sql` | твой: индексы и повторный `EXPLAIN ANALYZE` |
| `db_audit/n_plus_one.py` | N+1 уже воспроизводится; `joinedload` и `selectinload` пишешь ты (функции с `TODO`) |
| `db_audit/scaling_strategy.md` | твой, план и ориентиры в [SCALING_GUIDE.md](SCALING_GUIDE.md) |

## Запуск базы

```sh
docker compose up -d
```

При первом старте с пустым томом контейнер сам выполнит `db_audit/schema.sql`. Генерация занимает около 3 минут, ход виден в `docker compose logs -f postgres`.

Подключение из GUI-клиента: `localhost:5433`, база `shop`, пользователь и пароль `app`. Порт 5433, а не 5432, чтобы не конфликтовать с Postgres из домашки по Redis.

## Данные

- 2 000 000 заказов за последние 365 дней. Число заказов в день растёт: сейчас их вдвое больше, чем год назад. `id` растёт вместе с `created_at`, как при настоящих вставках.
- ~7 000 000 позиций, от 1 до 6 на заказ.
- 20 000 пользователей. Активные заказывают чаще, поэтому у пользователей с маленькими `id` заказов больше.
- 2 000 товаров с ценами от 20 до ~3 000. Популярность неравномерная: несколько десятков товаров дают большую часть продаж.
- Статус зависит от возраста заказа. Свежие заказы в `pending`, `processing` и `shipped`, старые в `completed`, `cancelled` и `refunded`. Доля `completed` около 80%.
- `total_amount` равен сумме `quantity * price` по позициям заказа. Около 6% заказов дороже 10 000.
- Индексов нет, кроме первичных ключей. Внешний ключ `order_items.order_id` индекс не создаёт.

Сид генератора фиксирован, поэтому при каждом запуске получаются одинаковые данные. Даты отсчитываются от момента генерации. Если с генерации прошло много времени, запросы «за последний месяц» начнут терять данные: пересоздай базу.

## Выполнение SQL-файлов

В образе есть `psql`, а папка `db_audit/` смонтирована в контейнер как `/db_audit`:

```powershell
docker compose exec postgres psql -U app -d shop -f /db_audit/queries.sql
```

В Git Bash путь `/db_audit/...` превращается в Windows-путь. Там добавляй префикс `MSYS_NO_PATHCONV=1`:

```sh
MSYS_NO_PATHCONV=1 docker compose exec postgres psql -U app -d shop -f /db_audit/queries.sql
```

Интерактивная консоль: `docker compose exec postgres psql -U app -d shop`.

### Сброс

- **Пересоздать таблицы и данные.** Заодно удалятся все индексы, созданные в экспериментах:
  ```powershell
  docker compose exec postgres psql -U app -d shop -f /db_audit/schema.sql
  ```
- **Снести базу целиком:** `docker compose down -v`, затем `docker compose up -d`.

## N+1

```sh
uv sync
uv run python db_audit/n_plus_one.py
```

Скрипт загружает 20 последних завершённых заказов и в цикле обращается к `order.items`. Каждый сценарий работает в отдельной сессии. В конце печатается сводка: число SQL-запросов и время по каждому сценарию. Пока реализован только ленивый сценарий: 21 запрос, а `joinedload` и `selectinload` пропускаются.

`SQL_ECHO=false` отключает лог SQL и оставляет только сводку. В PowerShell: `$env:SQL_ECHO="false"; uv run python db_audit/n_plus_one.py`.

Обрати внимание на время одного запроса за позициями. Без индекса по `order_items.order_id` каждый из N запросов делает Seq Scan по 7 миллионам строк. Сравни время до и после создания индексов из пункта 3: это наглядно показывает, как N+1 умножает цену плохого плана.

## Полезное для EXPLAIN

- `EXPLAIN (ANALYZE, BUFFERS)` показывает не только время, но и число прочитанных страниц: `shared hit` берётся из кэша, `read` с диска. Страницы сравнивать надёжнее, чем миллисекунды.
- Запускай запрос 2-3 раза. Первый прогон холодный, и его время сильно зависит от кэша.
- Если параллельные планы (`Gather`, `Parallel Seq Scan`) мешают читать план, в текущей сессии можно сделать `SET max_parallel_workers_per_gather = 0;`.
- Включён `pg_stat_statements`. Самые тяжёлые запросы за всё время:
  ```sql
  SELECT calls, round(total_exec_time) AS total_ms, round(mean_exec_time, 2) AS mean_ms, query
  FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
  ```
