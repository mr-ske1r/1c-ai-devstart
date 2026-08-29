#!/usr/bin/env python3
"""Границы доработок объекта 1С: что изменено относительно эталона поставщика.

Печатает только расхождения: для BSL — правки с именем процедуры, для XML —
смысловую сводку (элементы, реквизиты, свойства, тексты запросов).

Принцип: сводка отчитывается за ВЕСЬ дифф. Каждое расхождение попадает либо
в понятную строку отчёта, либо в раздел «не классифицировано» с указанием узла.
Молча потерять правку нельзя — это опаснее многословия.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PROC_RE = re.compile(r"^\s*(?:&\S+\s*)?(Процедура|Функция)\s+([^\s(]+)", re.I)
# Похоже на маркер доработки: дата либо явное слово. «изменено/добавлено» намеренно
# не берём — это обычная проза в типовых комментариях и даёт сплошные ложные срабатывания.
MARKER_HINT_RE = re.compile(r"^\s*//.*(доработк|правк|\d{2}\.\d{2}\.\d{4})", re.I)
# Секционные комментарии БСП маркерами не являются.
BSP_COMMENT_RE = re.compile(r"^\s*//\s*(Конец\s+)?СтандартныеПодсистемы\.", re.I)
TOKEN_RE = re.compile(r"[A-Za-zА-Яа-яЁё_][A-Za-zА-Яа-яЁё0-9_]*|\S")
LONG_TEXT = 200          # длиннее — показываем текстовым диффом
NOISE_FILES = {"ConfigDumpInfo.xml", "ParentConfigurations.bin"}


def read_lines(path):
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        return f.read().splitlines()


def resolve_vendor(path, vendor_root, work_root):
    ap = os.path.abspath(path).replace("\\", "/")
    if vendor_root and work_root:
        wr = os.path.abspath(work_root).replace("\\", "/").rstrip("/")
        vr = os.path.abspath(vendor_root).replace("\\", "/").rstrip("/")
        if ap.startswith(wr + "/"):
            return os.path.join(vr, ap[len(wr) + 1:])
        return None
    for src, dst in (("/src/cf/", "/src/cf_vendor/"), ("/cf/", "/cf_vendor/")):
        i = ap.rfind(src)
        if i != -1:
            return ap[:i] + dst + ap[i + len(src):]
    return None


def short(v, limit=70):
    v = " ".join(str(v).split())
    return v if len(v) <= limit else v[:limit] + "…"


# ---------------------------------------------------------------- BSL

def procedure_map(lines):
    owner, cur = {}, "(вне процедуры)"
    for i, line in enumerate(lines, 1):
        if PROC_RE.match(line):
            cur = line.strip()
        owner[i] = cur
    return owner


def norm(s):
    return re.sub(r"\s+", "", s)


def only_comments(lines):
    """Все содержательные строки — комментарии."""
    body = [l for l in lines if l.strip()]
    return bool(body) and all(l.strip().startswith("//") for l in body)


def code_unchanged(removed, added):
    """Код тот же, изменились только комментарии и отступы.

    Частый случай в старых базах: вендорскую строку обернули маркерами,
    ничего не поменяв. Переносить нечего.
    """
    def code(lines):
        return norm("".join(l for l in lines if not l.strip().startswith("//")))
    if code(removed) != code(added):
        return False
    cm_r = [l for l in removed if l.strip().startswith("//")]
    cm_a = [l for l in added if l.strip().startswith("//")]
    return bool(cm_r or cm_a)


def reformat_pairs(removed, added):
    """Сколько строк правки различаются только пробелами и табами."""
    n = 0
    for a, b in zip(removed, added):
        if a != b and norm(a) == norm(b):
            n += 1
    return n


def token_substitution(removed, added):
    """Сводится ли правка к замене одного идентификатора на другой."""
    if not removed or len(removed) != len(added):
        return None
    subs = set()
    for a, b in zip(removed, added):
        ta, tb = TOKEN_RE.findall(a), TOKEN_RE.findall(b)
        sm = difflib.SequenceMatcher(None, ta, tb, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == "equal":
                continue
            if tag == "replace" and (i2 - i1) == (j2 - j1):
                for k in range(i2 - i1):
                    subs.add((ta[i1 + k], tb[j1 + k]))
            else:
                return None
        if len(subs) > 1:
            return None
    return subs.pop() if len(subs) == 1 else None


def bsl_hunks(vendor_lines, work_lines, ctx=3):
    """Один хирург = одна непрерывная серия изменений.

    Намеренно НЕ используем get_grouped_opcodes: он склеивает близкие правки
    из разных процедур в один кусок, и чистое удаление кода вендора теряется
    внутри соседней замены — а его нельзя решать молча.
    """
    owner = procedure_map(work_lines)
    ops = difflib.SequenceMatcher(None, vendor_lines, work_lines,
                                  autojunk=False).get_opcodes()
    hunks, i = [], 0
    while i < len(ops):
        if ops[i][0] == "equal":
            i += 1
            continue
        j = i
        while j < len(ops):
            while j < len(ops) and ops[j][0] != "equal":
                j += 1
            # Разрыв только из пустых строк — это одна правка, разорванная
            # переотступом. Иначе чистое удаление и соседняя вставка выглядят
            # как отдельные события, и тревога о потере кода вендора ложная.
            if (j < len(ops) - 1 and ops[j][0] == "equal"
                    and all(not work_lines[k].strip()
                            for k in range(ops[j][3], ops[j][4]))):
                j += 1
                continue
            break
        run = [o for o in ops[i:j] if o[0] != "equal"]
        gap = [o for o in ops[i:j] if o[0] == "equal"]

        removed = [vendor_lines[k] for _, a, b, _, _ in run for k in range(a, b)]
        added = [work_lines[k] for _, _, _, c, d in run for k in range(c, d)]
        start, end = run[0][3] + 1, run[-1][4]

        body = []
        if i > 0:
            p = ops[i - 1]
            body += ["  " + work_lines[k] for k in range(max(p[3], p[4] - ctx), p[4])]
        for op in sorted(ops[i:j], key=lambda o: o[3]):
            t, a, b, c, d = op
            if t == "equal":
                body += ["  " + work_lines[k] for k in range(c, d)]
                continue
            body += ["- " + vendor_lines[k] for k in range(a, b)]
            body += ["+ " + work_lines[k] for k in range(c, d)]
        if j < len(ops):
            p = ops[j]
            body += ["  " + work_lines[k] for k in range(p[3], min(p[4], p[3] + ctx))]

        kind = ("ЗАМЕНА" if added and removed
                else "ВСТАВКА" if added else "ЧИСТОЕ УДАЛЕНИЕ")
        new_proc = next((l.strip() for l in added if PROC_RE.match(l)), None)
        hunks.append({
            "kind": kind,
            "owner": new_proc or owner.get(start, "(вне процедуры)"),
            "new_method": bool(new_proc),
            "start": start, "end": max(end, start),
            "body": body,
            "fmt_only": norm("\n".join(removed)) == norm("\n".join(added)),
            # Считаем по объединению: удаление комментария вендора даёт пустую
            # добавленную часть, и попарная проверка такой случай упускает.
            "comments_only": only_comments(removed + added),
            "code_same": code_unchanged(removed, added),
            "reformat": reformat_pairs(removed, added),
            "sub": token_substitution(removed, added),
            "exact": (norm("\n".join(removed)), norm("\n".join(added))),
        })
        i = j
    return hunks


def group_hunks(hunks):
    """Одна и та же правка в нескольких местах — одна доработка."""
    groups, order = {}, []
    for h in hunks:
        key = ("SUB",) + h["sub"] if h["sub"] else ("EXACT",) + h["exact"]
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(h)
    return [(k, groups[k]) for k in order]


def report_bsl(rel, vendor, work, show_body=True):
    v, w = read_lines(vendor), read_lines(work)
    hunks = bsl_hunks(v, w)
    if not hunks:
        return 0
    groups = group_hunks(hunks)
    def noise(h):
        return h["fmt_only"] or h["comments_only"] or h["code_same"]

    real = [(k, g) for k, g in groups if not noise(g[0])]
    fmt = [(k, g) for k, g in groups if g[0]["fmt_only"]]
    cmt = [(k, g) for k, g in groups
           if g[0]["comments_only"] and not g[0]["fmt_only"]]
    wrap = [(k, g) for k, g in groups
            if g[0]["code_same"] and not g[0]["fmt_only"] and not g[0]["comments_only"]]

    folded = sum(len(g) - 1 for _, g in groups)
    print(f"\n{'=' * 70}\nМОДУЛЬ: {rel}")
    print(f"Хирургов: {len(hunks)}. Из них: смысловых правок {len(real)}, "
          f"только форматирование {len(fmt)}, только комментарии {len(cmt)}, "
          f"код не изменён (обёртка маркерами) {len(wrap)}, "
          f"свёрнуто как повторы одной правки {folded}.")
    total_g = len(real) + len(fmt) + len(cmt) + len(wrap) + folded
    print(f"Проверка: {len(real)}+{len(fmt)}+{len(cmt)}+{len(wrap)}+{folded} = {total_g}"
          + ("" if total_g == len(hunks) else "  !! не сходится с числом хирургов"))

    for n, (key, g) in enumerate(real, 1):
        h = g[0]
        kind = h["kind"] + (" (новый метод)" if h["new_method"] else "")
        print(f"\n--- Правка {n}: {kind}")
        if key[0] == "SUB" and len(g) > 1:
            print(f"    Одна и та же замена: {key[1]} -> {key[2]}")
        elif key[0] == "SUB":
            print(f"    Замена: {key[1]} -> {key[2]}")
        if h["reformat"]:
            print(f"    Из них строк только с переотступом: {h['reformat']} — "
                  f"это форматирование, не доработка")
        if len(g) > 1:
            print(f"    ОДНА И ТА ЖЕ ПРАВКА В {len(g)} МЕСТАХ:")
            for x in g:
                print(f"      • {x['owner']} — стр. {x['start']}-{x['end']}")
        else:
            print(f"    Место: {h['owner']} (стр. {h['start']}-{h['end']})")
        if h["kind"] == "ЧИСТОЕ УДАЛЕНИЕ":
            print("    ! Удалён код вендора без замены — не решать молча, спросить пользователя")
        if show_body and (len(g) == 1 or key[0] != "SUB"):
            print("\n".join("    " + b for b in h["body"]))
        elif show_body:
            print("\n".join("    " + b for b in h["body"]))
            if len(g) > 1:
                print(f"    (остальные {len(g) - 1} места — та же замена)")

    for key, g in fmt:
        h = g[0]
        print(f"\n--- Только форматирование ({len(g)} мест, первое: {h['owner']} "
              f"стр. {h['start']}-{h['end']}) — переносить нечего")
    for key, g in cmt:
        h = g[0]
        print(f"\n--- Только комментарии ({len(g)} мест, первое: {h['owner']} "
              f"стр. {h['start']}-{h['end']}) — поведение не меняется, "
              f"переносить нечего; возврат к эталону восстановит текст вендора")

    hints = [f"стр. {i}: {l.strip()}" for i, l in enumerate(w, 1)
             if MARKER_HINT_RE.match(l) and not BSP_COMMENT_RE.match(l)
             and "+++" not in l and "---" not in l]
    if hints:
        print("\n    ВНИМАНИЕ: комментарии, похожие на маркеры старого образца:")
        for x in hints[:10]:
            print(f"      {x}")
        if len(hints) > 10:
            print(f"      … показаны первые 10 из {len(hints)}")
        print("    Это догадка. Автор, дата и номер задачи оттуда фактом не являются.")
    return len(real)


# ---------------------------------------------------------------- XML

def tag_of(e):
    return e.tag.split("}")[-1]


ROOT_OWNER = ("", "(корень)")


def label(key):
    """Читаемое имя элемента: раздел важен, иначе реквизит и поле формы сливаются."""
    section, name = key
    if section in ("", "ChildItems"):
        return name
    return f"{name} [{section}]"


ТИП_ВЫЗОВА = {"Before": "Перед", "After": "После", "Override": "Вместо"}


def подпись(key, инфо):
    """Читаемая строка элемента. Для привязки события — обработчик и тип вызова.

    `callType` в выгрузке английский, а в палитре свойств Конфигуратора
    пользователь видит «Перед»/«После»/«Вместо» — печатаем то, что он узнает.
    """
    if инфо and инфо.get("тег") == "Event":
        вызов = ТИП_ВЫЗОВА.get(инфо.get("вызов"), "обычная привязка, не перехват")
        return (f"{инфо.get('событие', key[1])} → "
                f"{инфо.get('обработчик') or '(обработчик не указан)'} [{вызов}]")
    return label(key)


def scan_xml(path):
    return scan_element(ET.parse(path).getroot())


def scan_element(root):
    """Возвращает (элементы, листья).

    элементы: (раздел, имя) -> {тег, родитель, путь}
      Ключ с разделом обязателен: реквизит формы и элемент формы могут иметь
      одно имя, и без раздела они склеиваются в один объект.
    листья: путь -> (значение, ключ владеющего элемента)
    """
    elements, leaves = {}, {}

    def walk(elem, prefix, owner, section):
        for k, v in elem.attrib.items():
            key = k.split("}")[-1]
            if key in ("id", "name"):     # id платформенный, name — в индексе элементов
                continue
            leaves[f"{prefix}@{key}"] = (v, owner)
        kids = list(elem)
        if not kids:
            text = (elem.text or "").strip()
            if text:
                leaves[prefix.rstrip("/")] = (text, owner)
            return
        counts = {}
        for c in kids:
            k = c.get("name") or tag_of(c)
            counts[k] = counts.get(k, 0) + 1
        seen = {}
        for c in kids:
            base = c.get("name") or tag_of(c)
            if counts[base] > 1:
                seen[base] = seen.get(base, 0) + 1
                key = f"{base}[{seen[base]}]"
            else:
                key = base
            sec = section if section is not None else key
            nm = c.get("name")
            child_owner = owner
            if nm:
                инфо = {"тег": tag_of(c), "родитель": owner, "путь": prefix + key}
                if tag_of(c) == "Event":
                    # Имя события не уникально: OnChange висит на каждом втором
                    # элементе, а на одном элементе их бывает два сразу («Перед»
                    # и «После»). Ключ по одному имени схлопывал их в одну запись,
                    # и привязки терялись молча — а по этому списку восстанавливают
                    # форму после обновления заимствования.
                    вызов = c.get("callType")
                    инфо.update({"событие": nm, "вызов": вызов,
                                 "обработчик": (c.text or "").strip()})
                    nm = f"{owner[1]}/{nm}" + (f":{вызов}" if вызов else "")
                child_owner = (sec, nm)
                elements[child_owner] = инфо
            walk(c, f"{prefix}{key}/", child_owner, sec)

    walk(root, "", ROOT_OWNER, None)
    return elements, leaves


def own_leaves(leaves, key):
    """Листья, принадлежащие именно этому элементу, без имени в ключе."""
    out = {}
    for path, (val, owner) in leaves.items():
        if owner == key:
            out[path.split("/")[-1]] = val
    return out


def detect_renames(removed, added, ev, ew, lv, lw):
    """Удалён один элемент, добавлен другой с тем же наполнением — это переименование."""
    renames, used = [], set()
    for r in list(removed):
        rl = own_leaves(lv, r)
        for a in list(added):
            if a in used or a[0] != r[0]:
                continue
            al = own_leaves(lw, a)
            if rl and rl == al:
                renames.append((r, a))
                used.add(a)
                removed.remove(r)
                added.remove(a)
                break
    return renames


def count_refs(name, root, skip):
    """Сколько раз имя встречается в соседних файлах объекта, кроме объявления."""
    n = 0
    for dirpath, _, files in os.walk(root):
        for f in files:
            full = os.path.abspath(os.path.join(dirpath, f))
            if full == skip or not f.lower().endswith((".bsl", ".xml")):
                continue
            try:
                n += open(full, encoding="utf-8-sig", errors="replace").read().count(name)
            except OSError:
                pass
    return n


def report_xml(rel, vendor, work, obj_root=None):
    try:
        ev, lv = scan_xml(vendor)
        ew, lw = scan_xml(work)
    except ET.ParseError as e:
        print(f"\n{'=' * 70}\nXML: {rel}\n  НЕ РАЗОБРАН ({e}) — сравни сырым diff")
        return 1

    added_el = [k for k in ew if k not in ev]
    removed_el = [k for k in ev if k not in ew]
    renamed = detect_renames(removed_el, added_el, ev, ew, lv, lw)
    moved_el = [k for k in ew if k in ev and ev[k]["родитель"] != ew[k]["родитель"]]

    add_leaf = {k: lw[k] for k in lw if k not in lv}
    del_leaf = {k: lv[k] for k in lv if k not in lw}
    chg_leaf = {k: (lv[k][0], lw[k][0], lw[k][1])
                for k in lw if k in lv and lv[k][0] != lw[k][0]}

    total = len(add_leaf) + len(del_leaf) + len(chg_leaf)
    if not (total or added_el or removed_el or moved_el or renamed):
        return 0

    print(f"\n{'=' * 70}\nXML: {rel}")

    # листья, объяснённые появлением, исчезновением, переездом или переименованием
    touched = set(added_el) | set(removed_el) | set(moved_el)
    for r, a in renamed:
        touched.add(r)
        touched.add(a)
    explained = {k for k, (_, o) in add_leaf.items() if o in touched}
    explained |= {k for k, (_, o) in del_leaf.items() if o in touched}
    explained |= {k for k, (_, _, o) in chg_leaf.items() if o in touched}

    if renamed:
        print("\n  ПЕРЕИМЕНОВАНЫ:")
        for r, a in sorted(renamed):
            print(f"    ~ {label(r)} -> {label(a)} ({ew[a]['тег']})")
    if added_el:
        print("\n  ДОБАВЛЕНЫ ЭЛЕМЕНТЫ:")
        for k in sorted(added_el):
            print(f"    + {label(k)} ({ew[k]['тег']}) в {label(ew[k]['родитель'])}")
            if obj_root and k[0] == "Attributes":
                refs = count_refs(k[1], obj_root, os.path.abspath(work))
                print(f"        ссылок в других файлах объекта: {refs}"
                      + ("  — реквизит нигде не используется, "
                         "проверь, не мёртвый ли он" if refs == 0 else ""))
            props = own_leaves(lw, k)
            if props:
                shown = {p: v for p, v in sorted(props.items()) if not p.startswith("@")}
                if shown:
                    print("        свойства: " + ", ".join(
                        f"{p}={short(v, 30)}" for p, v in list(shown.items())[:8]))
            else:
                print("        свойства не заданы — действуют умолчания платформы")
    if removed_el:
        print("\n  УДАЛЕНЫ ЭЛЕМЕНТЫ:")
        for k in sorted(removed_el):
            print(f"    - {label(k)} ({ev[k]['тег']}) из {label(ev[k]['родитель'])}")
    if moved_el:
        print("\n  ПЕРЕМЕЩЕНЫ:")
        for k in sorted(moved_el):
            print(f"    ~ {label(k)}: {label(ev[k]['родитель'])} -> {label(ew[k]['родитель'])}")

    # следствия переименования: значение сменилось со старого имени на новое
    ren_map = {r[1]: a[1] for r, a in renamed}
    consequence = {k for k, (a, b, _) in chg_leaf.items()
                   if a in ren_map and b == ren_map[a]}
    if consequence:
        print("\n  СЛЕДСТВИЯ ПЕРЕИМЕНОВАНИЯ (отдельной доработкой не считать):")
        for k in sorted(consequence):
            a, b, o = chg_leaf[k]
            nm = label(o) if o != ROOT_OWNER else ""
            print(f"    ~ {nm}.{k.split('/')[-1]}: {short(a)} -> {short(b)}")

    rest_chg = {k: v for k, v in chg_leaf.items()
                if k not in explained and k not in consequence}
    if rest_chg:
        print("\n  ИЗМЕНЕНЫ СВОЙСТВА:")
        for k, (a, b, o) in sorted(rest_chg.items()):
            nm = label(o) if o != ROOT_OWNER else ""
            lbl = f"{nm}.{k.split('/')[-1]}" if nm else k
            if len(a) > LONG_TEXT or len(b) > LONG_TEXT:
                print(f"    ~ {lbl} — длинный текст, дифф:")
                for line in difflib.unified_diff(
                        a.splitlines(), b.splitlines(),
                        "эталон", "текущий", lineterm="", n=2):
                    print(f"        {line}")
            else:
                print(f"    ~ {lbl}: {short(a)!r} -> {short(b)!r}")

    rest_add = {k: v for k, v in add_leaf.items() if k not in explained}
    rest_del = {k: v for k, v in del_leaf.items() if k not in explained}
    for title, data in (("ДОБАВЛЕНЫ УЗЛЫ", rest_add), ("УДАЛЕНЫ УЗЛЫ", rest_del)):
        if not data:
            continue
        print(f"\n  {title} ({len(data)}):")
        by_owner = {}
        for k, val in data.items():
            by_owner.setdefault(val[1], []).append(k)
        for owner, keys in sorted(by_owner.items()):
            print(f"    в {label(owner)}: {len(keys)}")
            for k in sorted(keys)[:6]:
                print(f"      {k} = {short(data[k][0], 50)!r}")
            if len(keys) > 6:
                print(f"      … ещё {len(keys) - 6}")

    n_expl = len(explained)
    n_shown = len(rest_chg) + len(consequence) + len(rest_add) + len(rest_del)
    print(f"\n  Учтено расхождений: {total} "
          f"(изменено {len(chg_leaf)}, добавлено {len(add_leaf)}, удалено {len(del_leaf)}).")
    print(f"    показаны отдельными строками: {n_shown}")
    print(f"    отнесены к добавленным, удалённым, перемещённым и переименованным "
          f"элементам выше: {n_expl}")
    if n_shown + n_expl != total:
        print(f"    !! НЕ КЛАССИФИЦИРОВАНО: {total - n_shown - n_expl}. "
              f"Это дефект разбора — сравни файл сырым diff, не доверяй сводке.")
    return 1


# ------------------------------------------------- ревизия форм расширения

# Платформа заводит эти узлы сама на каждый элемент формы — собственными
# изменениями расширения они не являются и только зашумляют ревизию.
SERVICE_TAGS = {"ExtendedTooltip", "ContextMenu", "AutoCommandBar",
                "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition"}


def split_ext_form(path):
    """Форма расширения = собственная часть + BaseForm (состояние до её правок)."""
    root = ET.parse(path).getroot()
    base = next((c for c in root if tag_of(c) == "BaseForm"), None)
    if base is None:
        return None, None
    own = ET.Element(root.tag, root.attrib)
    for c in root:
        if tag_of(c) != "BaseForm":
            own.append(c)
    return own, base


def report_ext_form(rel, ext_path, vendor_path, work_path=None):
    """Что расширение добавляет от себя и не испорчена ли его база."""
    own, base = split_ext_form(ext_path)
    if own is None:
        return 0

    eo, lo = scan_element(own)
    eb, lb = scan_element(base)

    ev, lv, ew = {}, {}, {}
    missing_vendor = not (vendor_path and os.path.isfile(vendor_path))
    if not missing_vendor:
        ev, lv = scan_xml(vendor_path)
    if work_path and os.path.isfile(work_path):
        ew, _ = scan_xml(work_path)

    own_add = [k for k in eo if k not in eb and eo[k]["тег"] not in SERVICE_TAGS]
    own_del = [k for k in eb if k not in eo and eb[k]["тег"] not in SERVICE_TAGS]
    # Заимствование видно только в разреженных секциях: там расширение перечисляет
    # ровно то, что втянуло в свою область видимости. В ChildItems оно хранит всё
    # дерево формы как контекст, и проверка по нему выдала бы форму целиком.
    adopted = [k for k in eo
               if k[0] in ("Attributes", "Events", "Commands", "Parameters")
               and k in eb and k in ev and eo[k]["тег"] not in SERVICE_TAGS]

    def service_owner(key):
        owner = lo[key][1]
        return owner in eo and eo[owner]["тег"] in SERVICE_TAGS

    # Значение, совпадающее с вендорским, правкой расширения не является:
    # в BaseForm у платформы там стоит заготовка, а не прежнее значение.
    own_chg = [k for k in lo
               if k in lb and lo[k][0] != lb[k][0] and not service_owner(k)
               and not (k in lv and lv[k][0] == lo[k][0])]

    # Испорченность = в BaseForm попало то, что есть в ДОРАБОТАННОЙ конфигурации,
    # но отсутствует у вендора. Чего нет ни там, ни там — артефакт платформы:
    # часть автогенерируемых элементов она материализует только в снимке расширения.
    poisoned = []
    if not missing_vendor and ew:
        poisoned = [k for k in eb if k not in ev and k in ew
                    and eb[k]["тег"] not in SERVICE_TAGS]
    unverifiable = bool(ew) is False and not missing_vendor

    if not (own_add or own_del or own_chg or adopted or poisoned or missing_vendor):
        return 0

    print(f"\n{'=' * 70}\nФОРМА РАСШИРЕНИЯ: {rel}")

    if adopted:
        print("\n  ЗАИМСТВОВАНО В РАСШИРЕНИЕ (типовые элементы в его области видимости):")
        for k in sorted(adopted):
            print(f"    = {подпись(k, eo[k])} ({eo[k]['тег']})")

    if own_add or own_del or own_chg:
        print("\n  СОБСТВЕННЫЕ ИЗМЕНЕНИЯ РАСШИРЕНИЯ (это и потеряется при обновлении "
              "заимствованной формы — снимай список ДО обновления):")
        for k in sorted(own_add):
            print(f"    + {подпись(k, eo[k])} ({eo[k]['тег']}) "
                  f"в {label(eo[k]['родитель'])}")
        for k in sorted(own_del):
            print(f"    - {подпись(k, eb[k])} ({eb[k]['тег']})")
        for k in sorted(own_chg)[:20]:
            o = lo[k][1]
            nm = label(o) if o != ROOT_OWNER else ""
            print(f"    ~ {nm}.{k.split('/')[-1]}: "
                  f"{short(lb[k][0], 40)} -> {short(lo[k][0], 40)}")
        if len(own_chg) > 20:
            print(f"    … ещё изменённых свойств: {len(own_chg) - 20}")
    else:
        print("\n  Собственных изменений формы расширение не несёт: его версия совпадает "
              "с BaseForm.\n  Такую форму проще убрать из расширения, чем чинить.")

    if missing_vendor:
        print("\n  Эталон формы не найден — проверить базу не с чем.")
    elif poisoned:
        print(f"\n  !! БАЗА ИСПОРЧЕНА: в BaseForm есть {len(poisoned)} элементов, "
              f"которых нет у вендора.")
        # Список не обрезаем: по нему восстанавливают потерянное после обновления
        # формы, и невыведенный элемент — молча потерянная правка расширения.
        for k in sorted(poisoned):
            print(f"    {label(k)} ({eb[k]['тег']})")
        print("  Форму заимствовали, когда основная конфигурация уже была доработана: "
              "снимок базы\n  вобрал чужие правки. После возврата основной конфигурации "
              "к вендору платформа\n  предложит обновить форму — и собственные изменения "
              "расширения при этом теряются.\n  Сначала сохрани список выше, потом обновляй.")
    else:
        print("\n  База в порядке: BaseForm не содержит ничего сверх вендорской формы.")
    return 1


def review_extension(ext_root, vendor_root, work_root=None):
    forms = []
    for root, _, files in os.walk(ext_root):
        for f in files:
            if f.lower() == "form.xml":
                forms.append(os.path.join(root, f))
    print(f"РЕВИЗИЯ РАСШИРЕНИЯ: {ext_root}")
    print(f"Форм найдено: {len(forms)}")
    flagged = 0
    for f in sorted(forms):
        rel = os.path.relpath(f, ext_root)
        vendor = os.path.join(vendor_root, rel) if vendor_root else None
        work = os.path.join(work_root, rel) if work_root else None
        flagged += report_ext_form(rel, f, vendor, work)
    print(f"\n{'=' * 70}\nФорм с замечаниями: {flagged} из {len(forms)}")
    return 1 if flagged else 0


# ---------------------------------------------------------------- обход

def walk_files(target):
    if os.path.isfile(target):
        return [target]
    out = []
    for root, _, files in os.walk(target):
        for f in sorted(files):
            out.append(os.path.join(root, f))
    # Описание объекта лежит рядом с папкой: Forms/ФормаДокумента/ + Forms/ФормаДокумента.xml.
    # Без него разбор папки молча неполон.
    sibling = os.path.normpath(target).rstrip("\\/") + ".xml"
    if os.path.isfile(sibling):
        out.append(sibling)
    return out


# ------------------------------------------------------- состояние в git

def _git_код(корень, *args):
    """Код возврата git-команды. None — git не запустился."""
    try:
        return subprocess.run(["git", "-C", корень, *args],
                              capture_output=True).returncode
    except OSError:
        return None


def _git_вывод(корень, *args):
    try:
        p = subprocess.run(["git", "-C", корень, *args], capture_output=True)
    except OSError:
        return None
    return p.stdout.decode("utf-8", "replace").strip() if p.returncode == 0 else None


def нечем_откатить(пути):
    """Какие из затираемых файлов не восстановить после записи.

    Проверяем только затираемые: создание файла ничего не теряет.
    Файл защищён, если git его отслеживает и содержимое совпадает с HEAD —
    тогда прежнее состояние достаётся обратно через git. Файл untracked,
    игнорируемый или изменённый после коммита существует только на диске:
    перезапись необратима.

    Проверка поштучная и по кодам возврата: разбирать вывод git с кириллицей
    в путях ненадёжно, он их экранирует.
    """
    if not пути:
        return [], ""
    корень = os.path.dirname(os.path.abspath(пути[0]))
    вершина = _git_вывод(корень, "rev-parse", "--show-toplevel")
    if вершина is None:
        return list(пути), ("git недоступен или каталог не в репозитории — "
                            "вернуть затёртое будет нечем")
    if _git_код(вершина, "rev-parse", "--verify", "-q", "HEAD") != 0:
        return list(пути), "в репозитории ещё нет ни одного коммита"
    опасные = [п for п in пути
               if _git_код(вершина, "ls-files", "--error-unmatch", "--", п) != 0
               or _git_код(вершина, "diff", "--quiet", "HEAD", "--", п) != 0]
    return опасные, "изменения не сохранены в коммите — после затирания их негде взять"


# --------------------------------------------------- версия конфигурации

def корень_конфигурации(старт, задан):
    if задан:
        return задан
    путь = os.path.abspath(старт)
    for _ in range(8):
        if os.path.isfile(os.path.join(путь, "Configuration.xml")):
            return путь
        род = os.path.dirname(путь)
        if род == путь:
            break
        путь = род
    return None


def описание_конфигурации(корень):
    """(имя, версия) из Configuration.xml или None, если файла нет."""
    if not корень:
        return None
    путь = os.path.join(корень, "Configuration.xml")
    if not os.path.isfile(путь):
        return None
    try:
        дерево = ET.parse(путь).getroot()
    except (ET.ParseError, OSError):
        return None
    имя = версия = None
    for e in дерево.iter():   # первые Name и Version в документе — самой конфигурации
        t = tag_of(e)
        if t == "Name" and имя is None:
            имя = (e.text or "").strip()
        elif t == "Version" and версия is None:
            версия = (e.text or "").strip()
        if имя and версия:
            break
    return (имя or "?", версия or "?")


# ---------------------------------------------------------------- запуск

def отказ(текст):
    """Скрипт не сделал работу. Код 2 отличает это от «расхождения остались»."""
    print(f"\nОТКАЗ: {текст}")
    return 2


def можно_вернуть(rel, include_xml):
    низ = rel.lower()
    if низ.endswith(".bsl"):
        return True
    return bool(include_xml) and низ.endswith(".xml")


def отсутствующие_у_рабочей(vendor_base, base):
    """Файлы, которые есть у вендора и которых нет в рабочей конфигурации.

    Обход одной рабочей стороны их не видит: удалённый модуль просто не
    попадает в перебор, и объект выглядит совпавшим с эталоном.
    """
    если_нет = []
    if not vendor_base or not os.path.isdir(vendor_base):
        return если_нет
    корень_v = os.path.abspath(vendor_base)
    кандидаты = [(os.path.relpath(vf, vendor_base),
                  os.path.join(base, os.path.relpath(vf, vendor_base)), vf)
                 for vf in walk_files(vendor_base)
                 if os.path.abspath(vf).startswith(корень_v + os.sep)]
    # Описание объекта лежит рядом с папкой, а не внутри неё.
    сосед_v = os.path.normpath(vendor_base).rstrip("\\/") + ".xml"
    if os.path.isfile(сосед_v):
        кандидаты.append((os.path.basename(сосед_v),
                          os.path.normpath(base).rstrip("\\/") + ".xml", сосед_v))
    for rel, wf, vf in кандидаты:
        if os.path.basename(vf) not in NOISE_FILES and not os.path.exists(wf):
            если_нет.append((rel, wf, vf))
    return если_нет


def main():
    ap = argparse.ArgumentParser(
        description="Расхождения объекта 1С с эталоном поставщика.")
    ap.add_argument("target", nargs="?", default=None,
                    help="файл или папка объекта в рабочей конфигурации "
                         "(в режиме --review-extension не нужен)")
    ap.add_argument("--vendor", help="парный файл эталона (для одиночного файла)")
    ap.add_argument("--vendor-root", help="корень эталона, например src/cf_vendor")
    ap.add_argument("--work-root", help="корень рабочей конфигурации, например src/cf")
    ap.add_argument("--no-body", action="store_true", help="без текста правок")
    ap.add_argument("--review-extension", metavar="КАТАЛОГ",
                    help="ревизия форм расширения: что оно добавляет от себя и не снят ли "
                         "его BaseForm с уже доработанной конфигурации")
    ap.add_argument("--restore", action="store_true",
                    help="вернуть файлы к эталону побайтно (кодировка и переводы строк "
                         "сохраняются). По умолчанию только модули BSL: XML в проектах "
                         "обычно в режиме «только чтение». Файл, чьи изменения не сохранены "
                         "в git, не затирается: откатывать было бы нечем.")
    ap.add_argument("--include-xml", action="store_true",
                    help="при --restore возвращать и XML. Только если таблица полномочий "
                         "проекта это разрешает.")
    ap.add_argument("--no-undo-confirmed", action="store_true",
                    help="разрешить --restore, когда затираемые файлы не сохранены в git "
                         "и вернуть их будет нечем. Ставится только по явному разрешению "
                         "пользователя на эту операцию, а не для обхода отказа.")
    args = ap.parse_args()

    if args.review_extension:
        if not os.path.isdir(args.review_extension):
            return отказ(f"каталог расширения не найден: {args.review_extension}")
        vr = args.vendor_root or (args.target if os.path.isdir(args.target or "") else None)
        if not vr or not os.path.isdir(vr):
            return отказ("укажи корень эталона: --vendor-root <каталог>.")
        return review_extension(args.review_extension, vr, args.work_root)

    if not args.target or not os.path.exists(args.target):
        return отказ(f"не найдено: {args.target}")

    одиночный = os.path.isfile(args.target)
    pairs, лишние = [], []
    for f in walk_files(args.target):
        if os.path.basename(f) in NOISE_FILES:
            continue
        v = (args.vendor if args.vendor and одиночный
             else resolve_vendor(f, args.vendor_root, args.work_root))
        if v and os.path.isfile(v):
            pairs.append((f, v))
        else:
            лишние.append(f)

    if not pairs:
        return отказ("эталон не найден. Укажи --vendor либо --vendor-root и --work-root,\n"
                     "либо положи эталон зеркально в src/cf_vendor.")

    base = args.target if os.path.isdir(args.target) else os.path.dirname(args.target)
    vendor_base = (os.path.dirname(args.vendor) if одиночный and args.vendor
                   else resolve_vendor(args.target, args.vendor_root, args.work_root))
    отсутствующие = ([] if одиночный
                     else отсутствующие_у_рабочей(vendor_base, base))

    print(f"ОБЪЕКТ: {args.target}")
    рабочая = описание_конфигурации(корень_конфигурации(base, args.work_root))
    эталонная = описание_конфигурации(
        корень_конфигурации(vendor_base or base, args.vendor_root))
    if рабочая or эталонная:
        показ = lambda o: " ".join(o) if o else "не определена"
        print(f"Конфигурация: рабочая — {показ(рабочая)}; эталон — {показ(эталонная)}")
        if рабочая and эталонная and рабочая != эталонная:
            print("  !! Имя или версия не совпадают. Тогда в дифф попадут не только "
                  "доработки, но и\n     изменения поставщика между релизами — а "
                  "выглядят они как локальные правки.\n     Прежде чем считать дифф "
                  "границами доработки, выясни у пользователя, тот ли эталон.")
    print(f"Файлов к сравнению: {len(pairs)}"
          + (f", только в рабочей: {len(лишние)}" if лишние else "")
          + (f", только у эталона: {len(отсутствующие)}" if отсутствующие else ""))

    changed = []
    for work, vendor in pairs:
        try:
            if open(work, "rb").read() == open(vendor, "rb").read():
                continue
        except OSError:
            pass
        rel = os.path.relpath(work, base)
        changed.append((rel, work, vendor))
        if args.restore:
            continue
        if work.lower().endswith(".bsl"):
            report_bsl(rel, vendor, work, show_body=not args.no_body)
        elif work.lower().endswith(".xml"):
            report_xml(rel, vendor, work,
                       obj_root=args.target if os.path.isdir(args.target) else None)
        else:
            print(f"\n{'=' * 70}\nФАЙЛ: {rel}\n  Не текст и не XML — разобрать нечем, "
                  f"проверь вручную")

    print(f"\n{'=' * 70}")

    if args.restore:
        затираемые = [x for x in changed if можно_вернуть(x[0], args.include_xml)]
        воссоздаваемые = [x for x in отсутствующие
                          if можно_вернуть(x[0], args.include_xml)]
        отложенные = ([x for x in changed if not можно_вернуть(x[0], args.include_xml)]
                      + [x for x in отсутствующие
                         if not можно_вернуть(x[0], args.include_xml)])

        if отложенные:
            print("НЕ ВОЗВРАЩАЕТСЯ АВТОМАТИЧЕСКИ (XML — только с --include-xml по "
                  "таблице полномочий\nпроекта; прочие типы скрипт не трогает "
                  "никогда — это работа для Конфигуратора):")
            for rel, _, _ in отложенные:
                print(f"  • {rel}")

        опасные, причина = нечем_откатить([w for _, w, _ in затираемые])
        if опасные and not args.no_undo_confirmed:
            print("\nЭти файлы будут затёрты, а прежнее содержимое взять негде:")
            for w in опасные:
                print(f"  • {os.path.relpath(w, base)}")
            return отказ(
                f"{причина}.\nЗакоммить их — и возврат станет обратимым через git. "
                "Если отката сознательно\nне нужно, пользователь подтверждает это "
                "отдельно, и только тогда — --no-undo-confirmed.")
        if опасные:
            print(f"\n!! Откат невозможен ({причина}), продолжаем по "
                  f"--no-undo-confirmed.")

        if not затираемые and not воссоздаваемые:
            print("\nИТОГ: возвращать нечего.")
            return 1 if отложенные or лишние else 0

        if затираемые:
            print("\nБУДУТ ЗАТЁРТЫ РАБОЧИЕ ФАЙЛЫ:")
            for rel, _, _ in затираемые:
                print(f"  • {rel}")
        if воссоздаваемые:
            print("\nБУДУТ ВОССОЗДАНЫ УДАЛЁННЫЕ ФАЙЛЫ ЭТАЛОНА:")
            for rel, _, _ in воссоздаваемые:
                print(f"  • {rel}")
        for rel, work, vendor in затираемые + воссоздаваемые:
            os.makedirs(os.path.dirname(os.path.abspath(work)), exist_ok=True)
            with open(vendor, "rb") as src, open(work, "wb") as dst:
                dst.write(src.read())

        остаток = [rel for rel, _, _ in отложенные] + \
                  [os.path.relpath(u, base) for u in лишние]
        print(f"\nИТОГ: возвращено файлов — {len(затираемые) + len(воссоздаваемые)}.")
        if not остаток:
            print("Объект приведён к состоянию эталона. "
                  "Сверься повторным прогоном без --restore.")
            return 0
        print("Объект к состоянию эталона НЕ приведён, осталось "
              f"{len(остаток)} — их скрипт вернуть не может:")
        for rel in остаток:
            print(f"  • {rel}")
        return 1

    всего = len(changed) + len(лишние) + len(отсутствующие)
    if not всего:
        print("ИТОГ: расхождений с эталоном нет.")
        return 0

    print(f"ИТОГ: расхождений — {всего}.")
    if changed:
        print(f"\nИзменены ({len(changed)}):")
        for rel, _, _ in changed:
            print(f"  • {rel}")
    if лишние:
        print(f"\nЕсть только в рабочей, эталонной пары нет ({len(лишние)}) — "
              "новый файл либо неполный\nэталон. Пока не разобрано, объект "
              "совпавшим с эталоном не считается. Автоматически\nэти файлы "
              "не удаляются: решение об удалении принимает пользователь.")
        for u in лишние:
            print(f"  • {os.path.relpath(u, base)}")
    if отсутствующие:
        print(f"\nЕсть у эталона и нет в рабочей ({len(отсутствующие)}) — "
              "файл удалён из основной\nконфигурации. Возврат к эталону "
              "воссоздаёт его.")
        for rel, _, _ in отсутствующие:
            print(f"  • {rel}")

    root = os.path.abspath(base)
    for _ in range(6):
        ext = [d for d in os.listdir(root) if d.startswith("cfe")] \
            if os.path.isdir(root) else []
        if ext:
            vr = args.vendor_root or "src/cf_vendor"
            wr = args.work_root or "src/cf"
            print("\nДО возврата к эталону прогони ревизию расширения: она покажет "
                  "собственные правки расширения,\nзаимствованные типовые элементы и "
                  "испорченную базу заимствованных форм.")
            for d in ext[:3]:
                print(f"  python {os.path.basename(__file__)} --review-extension "
                      f"{os.path.join(os.path.relpath(root), d)} "
                      f"--vendor-root {vr} --work-root {wr}")
            break
        parent = os.path.dirname(root)
        if parent == root:
            break
        root = parent

    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
