---
name: 1c-odata
description: "Чтение данных из информационной базы 1С:Предприятие, опубликованной по OData, через curl и Basic Auth. Запасной путь к данным: используй, только когда MCP-сервер 1С не подключён или не отвечает, либо пользователь прямо просит OData. Если MCP доступен, данные бери запросом через него (см. .claude/rules/mcp.md и скилл mcp-1c). Отличие от соседей: этот скилл - чтение живых данных по HTTP без MCP; 1c-integrations - написание HTTP-клиентов/обменов в коде BSL."
---

# 1C OData Skill

Interact with a 1C:Enterprise database published via OData v3. All requests use `curl` + Basic Auth; no MCP server required.

**Windows note**: Node.js is required for Cyrillic URL encoding on Windows (curl on Windows mangles Cyrillic in URLs). The script handles this automatically if `node` is in PATH.

## 1. Connection Setup

The script auto-loads `.env` from the current working directory. Source it or just run the script — credentials are picked up automatically.

Expected `.env` format:
```
ODATA_URL=http://localhost/DemoSSL_3_1_10_369/odata/standard.odata
ODATA_USER=Администратор
ODATA_PASSWORD=
```

If `.env` doesn't exist — ask the user for these three values before proceeding.

## 2. Using the Query Script

The script `scripts/odata_query.sh` handles encoding, auth, and all OData parameters. Always use it instead of raw curl.

```bash
# With .env auto-loaded (no -u/-p needed if .env is set):
bash skills/1c-odata/scripts/odata_query.sh -e ENTITY_NAME [options]

# Or with explicit credentials:
bash skills/1c-odata/scripts/odata_query.sh \
  -b "$ODATA_URL" -u "$ODATA_USER" -p "$ODATA_PASSWORD" \
  -e ENTITY_NAME [options]
```

Key flags:
| Flag | OData param | Example |
|------|------------|---------|
| `-e` | entity name | `-e "Catalog__ДемоНоменклатура"` |
| `-t` | `$top` | `-t 20` |
| `-k` | `$skip` | `-k 40` |
| `-s` | `$select` | `-s "Ref_Key,Description,Code"` |
| `-f` | `$filter` | `-f "DeletionMark eq false"` |
| `-o` | `$orderby` | `-o "Date desc"` |
| `-x` | `$expand` | `-x "Document__ДемоРеализация_Товары"` |
| `--count` | `/$count` endpoint | returns a plain integer |
| `--inline-count` | `$inlinecount=allpages` | count + records together |

## 3. Discovering Available Entities

**Start here** — not all 1C objects are published. Only what the administrator explicitly enabled is accessible.

```bash
# List published entities
bash skills/1c-odata/scripts/odata_query.sh -e ""
```

The response is JSON with a `value` array. Entity names tell you what's available.

If the entity you need is missing, tell the user: *"Entity X is not published in this OData service. Ask the administrator to add it in Администрирование → Публикация на веб-сервере → вкладка OData."*

**Get full schema (field names and types):**
```bash
bash skills/1c-odata/scripts/odata_query.sh -e '$metadata' -F xml
```
Look for `<EntityType Name="...">` sections and their `<Property>` children.

**Inspect one record to discover fields:**
```bash
bash skills/1c-odata/scripts/odata_query.sh -e "EntityName" -t 1
```

## 4. 1C Entity Naming

| 1C Object Type | OData Prefix | Example |
|----------------|--------------|---------|
| Справочник | `Catalog_` | `Catalog_Контрагенты` |
| Документ | `Document_` | `Document_РеализацияТоваровУслуг` |
| Рег. сведений | `InformationRegister_` | `InformationRegister_ЦеныНоменклатуры` |
| Рег. накопления | `AccumulationRegister_` | `AccumulationRegister_Продажи` |
| Перечисление | `Enum_` | `Enum_ВидыНоменклатуры` |
| План счетов | `ChartOfAccounts_` | `ChartOfAccounts_Хозрасчетный` |

**Double-underscore rule**: if the object name starts with `_` (common in demo bases), OData name gets `__`:
- Object `_ДемоНоменклатура` → entity `Catalog__ДемоНоменклатура`

## 5. Query Patterns

### Filter examples

```bash
# Active records only
-f "DeletionMark eq false"

# String contains
-f "substringof('Стол',Description)"

# String starts with
-f "startswith(Description,'ООО')"

# Date range
-f "Date ge datetime'2024-01-01T00:00:00' and Date le datetime'2024-12-31T23:59:59'"

# By GUID reference key
-f "Ref_Key eq guid'12345678-abcd-abcd-abcd-123456789012'"

# Boolean
-f "Posted eq true"
```

### Count records

```bash
# Plain count (fastest)
bash skills/1c-odata/scripts/odata_query.sh -e "Catalog__ДемоНоменклатура" --count
# → 46

# Count with filter
bash skills/1c-odata/scripts/odata_query.sh -e "Catalog__ДемоНоменклатура" -f "DeletionMark eq false" --count
```

### Expand related entities (tabular parts)

```bash
bash skills/1c-odata/scripts/odata_query.sh \
  -e "Document__ДемоРеализация" -t 3 \
  -x "Document__ДемоРеализация_Товары"
```

Tabular part naming: `DocumentEntityName_TablePartName` (e.g., `Document__ДемоРеализация_Товары`).

### Pagination

```bash
-t 50 -k 0    # page 1
-t 50 -k 50   # page 2
-t 50 -k 100  # page 3
```

## 6. Parsing 1C-Specific Data Types

**Dates** — 1C returns `/Date(ms)/` format. Convert with node (available on Windows):
```bash
node -e "
const ms = 1704067200000;
console.log(new Date(ms).toLocaleString('ru-RU'));
"
```

Or for a batch of records (parse the JSON response):
```bash
node -e "
const fs = require('fs');
const data = JSON.parse(fs.readFileSync('response.json', 'utf8'));
data.value.forEach(r => {
  const ms = parseInt(r.Date.match(/\d+/)[0]);
  console.log(new Date(ms).toLocaleDateString('ru-RU'), r.Number, r.СуммаДокумента);
});
"
```

**GUIDs** — stored in `Ref_Key`, `*_Key` fields. Use in filter:
```
-f "НоменклатураRef_Key eq guid'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
```

**Enums** — stored as a URL string: `"ТипЦены_Key": "Enum_ТипЦен/ОсновнаяЦенаПродажи"`.

## 7. Analytical Workflow

When the user asks a business question about 1C data:

1. **Check what's published** — run `scripts/odata_query.sh -e ""` to see available entities.
2. **Identify the right entity** — documents/registers for operational data, catalogs for reference.
3. **Sample one record** to discover field names: `-t 1`
4. **Query with filters** — use `-s` to select only needed fields, `-f` to filter.
5. **Aggregate locally** — OData v3 has no server-side GROUP BY. Save response and aggregate with node:
   ```bash
   bash skills/1c-odata/scripts/odata_query.sh -e EntityName -t 1000 > /tmp/data.json
   node -e "
   const d = require('/tmp/data.json');
   const total = d.value.reduce((s,r) => s + r.СуммаДокумента, 0);
   console.log('Итого:', total);
   "
   ```
6. **Present results** as a markdown table.

## 8. Error Reference

| HTTP Code | Cause | Fix |
|-----------|-------|-----|
| 401 | Wrong credentials | Check ODATA_USER / ODATA_PASSWORD in .env |
| 403 | User lacks rights | Check 1C user roles for this entity |
| 404 | Wrong entity name | Run `-e ""` to list published entities |
| 400 | Bad OData syntax | Check filter; escape single quotes as `''` |
| OData error -1 | Internal 1C error (transient) | Retry; check 1C technology log |
| Response is XML | `$format=json` not applied | The script adds it automatically |
| Entity not in list | Not published in OData | Ask administrator to publish it |

**Debug raw response:**
```bash
bash skills/1c-odata/scripts/odata_query.sh -e "EntityName" -t 1 2>&1
# stderr shows the actual URL being called
```