#Requires -Version 7
<#
.SYNOPSIS
  Потоковая статистика и фильтрация журнала регистрации 1С старого формата (1CV8LOG ver 2.0, .lgf + .lgp).

.DESCRIPTION
  Mode Stats  — ничего не пишет; считает записи и байты по (событие, важность, статус транзакции),
                отдельно — сколько попадает под правило удаления. Запускать первым.
  Mode Filter — пишет новый .lgp: заголовок байт в байт, оставленные записи через ",`r`n", у последней
                запятой нет. Порядок и байты оставленных записей не меняются. Исходник только читается.

  Правило удаления: событие из -DropEvent (имена из .lgf), важность -DropSeverity (если задана),
  комментарий начинается с -CommentPrefix (если задан). С -LinkEmptyRollback дополнительно удаляется
  пустая откатанная транзакция (_$Transaction$_.Begin + _$Transaction$_.Rollback со статусом R) того же
  соединения, стоящая непосредственно перед удаляемой записью (не дальше 2 секунд).
  Без -DropEvent правило пустое: Filter даёт копию, совпадающую с исходником байт в байт (самопроверка).

  .lgx не создаётся и не копируется: это индекс со смещениями в .lgp, платформа строит его заново.

.EXAMPLE
  .\Filter-1CLog.ps1 -Mode Stats -Lgp D:\log\20231107000000.lgp -Lgf D:\log\1Cv8.lgf -OutDir D:\work\stats
.EXAMPLE
  .\Filter-1CLog.ps1 -Mode Filter -Lgp ... -Lgf ... -OutDir D:\work\out\1Cv8Log -ReportDir D:\work\out `
    -DropEvent 'Обновление информационной базы.Ошибка блокировки' -DropSeverity W `
    -CommentPrefix 'Пространство блокировки: Документ.УведомлениеОбИзмененииРасчетаПособия' -LinkEmptyRollback
#>
param(
    [Parameter(Mandatory)][ValidateSet('Stats', 'Filter')][string]$Mode,
    [Parameter(Mandatory)][string]$Lgp,
    [Parameter(Mandatory)][string]$Lgf,
    [Parameter(Mandatory)][string]$OutDir,
    [string[]]$DropEvent = @(),
    [ValidateSet('', 'I', 'W', 'E', 'N')][string]$DropSeverity = '',
    [string]$CommentPrefix = '',
    [switch]$LinkEmptyRollback,
    # Обработать только первые N байт (быстрый срез для проверки).
    [long]$MaxBytes = 0,
    [int]$Window = 256,
    [int]$SampleCount = 100,
    # Каталог отчётов; по умолчанию OutDir. Отдельный нужен, когда OutDir — это 1Cv8Log.
    [string]$ReportDir = ''
)

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public class LgpRecord {
    public byte[] Data; public int Len;
    public long Date; public byte Status; public string Trx; public long Conn;
    public int Event; public byte Sev; public bool Match; public bool Remove;
    public string CommentHead;
}

public class LgpFilter {
    public int EvBegin, EvRollback, WindowSize = 256, SampleCount = 100;
    public HashSet<int> DropEvents = new HashSet<int>();
    public byte DropSev;          // 0 — любая важность
    public byte[] Prefix = new byte[0];
    public bool LinkTrx;
    public long MaxBytes;

    public long Total, Kept, Removed, RemovedBytes, KeptBytes, Matched, LinkedTrx, Broken;
    public long BytesRead;
    public string FirstDate = "", LastDate = "";
    public Dictionary<string, long[]> Stats = new Dictionary<string, long[]>();
    public Dictionary<string, long> MatchHeads = new Dictionary<string, long>();

    List<LgpRecord> win = new List<LgpRecord>();
    Stream outS; Stream sampleS; int sampleLeft; bool firstOut = true;
    static readonly byte[] Sep = { (byte)',', (byte)'\r', (byte)'\n' };

    public void Run(string input, string output, string sample) {
        sampleLeft = SampleCount;
        using (var inS = new FileStream(input, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1 << 16, FileOptions.SequentialScan)) {
            // PowerShell передаёт $null в string как "", поэтому проверка на пустую строку.
            if (!string.IsNullOrEmpty(output)) outS = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 24);
            if (!string.IsNullOrEmpty(sample)) sampleS = new FileStream(sample, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16);
            try { Scan(inS); }
            finally {
                if (outS != null) outS.Dispose();
                if (sampleS != null) sampleS.Dispose();
            }
        }
    }

    // Запись — от '{' на нулевой глубине до парной '}'. Скобки внутри строк в кавычках не считаются;
    // удвоенная кавычка внутри строки переключает состояние дважды и ничего не ломает.
    void Scan(Stream inS) {
        byte[] buf = new byte[1 << 23];
        byte[] rec = new byte[1 << 16]; int recLen = 0;
        bool inQuote = false, inRec = false, header = true, stop = false;
        int depth = 0;
        var head = new MemoryStream();
        long nextReport = 1L << 30;
        int n;
        while (!stop && (n = inS.Read(buf, 0, buf.Length)) > 0) {
            int segStart = inRec ? 0 : -1;   // запись могла начаться в прошлом блоке
            for (int i = 0; i < n; i++) {
                byte b = buf[i];
                if (!inRec) {
                    if (b == (byte)'{') {
                        if (header) { header = false; if (outS != null) head.WriteTo(outS); }
                        inRec = true; depth = 1; inQuote = false; recLen = 0; segStart = i;
                    } else if (header) {
                        head.WriteByte(b);
                    } else if (b != (byte)',' && b != (byte)'\r' && b != (byte)'\n' && b != (byte)' ') {
                        Broken++;
                    }
                    continue;
                }
                if (b == (byte)'"') inQuote = !inQuote;
                else if (!inQuote) {
                    if (b == (byte)'{') depth++;
                    else if (b == (byte)'}' && --depth == 0) {
                        Append(ref rec, ref recLen, buf, segStart, i - segStart + 1);
                        segStart = -1; inRec = false;
                        OnRecord(rec, recLen);
                        if (MaxBytes > 0 && BytesRead + i >= MaxBytes) { stop = true; break; }
                    }
                }
            }
            if (inRec) Append(ref rec, ref recLen, buf, segStart, n - segStart);
            BytesRead += n;
            if (BytesRead >= nextReport) {
                Console.WriteLine("  {0:N1} ГБ, записей {1:N0}, последняя дата {2}", BytesRead / 1073741824.0, Total, LastDate);
                nextReport += 1L << 30;
            }
        }
        if (inRec) { Broken++; Console.WriteLine("ВНИМАНИЕ: файл оборван внутри записи, хвост {0} байт отброшен", recLen); }
        while (win.Count > 0) Pop();
    }

    static void Append(ref byte[] rec, ref int len, byte[] src, int off, int cnt) {
        if (len + cnt > rec.Length) {
            int sz = rec.Length; while (sz < len + cnt) sz *= 2;
            Array.Resize(ref rec, sz);
        }
        Buffer.BlockCopy(src, off, rec, len, cnt); len += cnt;
    }

    void OnRecord(byte[] rec, int len) {
        var r = new LgpRecord { Data = new byte[len], Len = len };
        Buffer.BlockCopy(rec, 0, r.Data, 0, len);
        Total++;
        if (!Parse(r)) Broken++;
        string d = r.Date.ToString();
        if (FirstDate == "") FirstDate = d;
        LastDate = d;
        if (r.Match) {
            Matched++;
            r.Remove = true;
            if (LinkTrx) LinkTransaction(r);
        }
        win.Add(r);
        if (win.Count > WindowSize * 2) while (win.Count > WindowSize) Pop();
    }

    // Пустая откатанная транзакция того же соединения прямо перед удаляемой записью.
    void LinkTransaction(LgpRecord w) {
        LgpRecord prev = null;
        for (int i = win.Count - 1; i >= 0; i--) if (win[i].Conn == w.Conn) { prev = win[i]; break; }
        if (prev == null || prev.Status != (byte)'R' || prev.Event != EvRollback) return;
        if (SecondsBetween(prev.Date, w.Date) > 2) return;
        var trx = new List<LgpRecord>();
        foreach (var q in win) {
            if (q.Trx != prev.Trx || q.Conn != w.Conn) continue;
            if (q.Status != (byte)'R' || (q.Event != EvBegin && q.Event != EvRollback)) return;
            trx.Add(q);
        }
        foreach (var q in trx) q.Remove = true;
        LinkedTrx++;
    }

    static long SecondsBetween(long a, long b) {
        try {
            var da = DateTime.ParseExact(a.ToString(), "yyyyMMddHHmmss", null);
            var db = DateTime.ParseExact(b.ToString(), "yyyyMMddHHmmss", null);
            return (long)Math.Abs((db - da).TotalSeconds);
        } catch { return long.MaxValue; }
    }

    void Pop() {
        var r = win[0]; win.RemoveAt(0);
        string key = r.Event + "|" + (char)r.Sev + "|" + (char)r.Status;
        long[] s;
        if (!Stats.TryGetValue(key, out s)) { s = new long[4]; Stats[key] = s; }
        s[0]++; s[1] += r.Len;
        if (r.Match && r.CommentHead != null) {
            long c; MatchHeads.TryGetValue(r.CommentHead, out c); MatchHeads[r.CommentHead] = c + 1;
        }
        if (r.Remove) {
            Removed++; RemovedBytes += r.Len; s[2]++; s[3] += r.Len;
            if (sampleS != null && sampleLeft > 0) {
                sampleLeft--;
                sampleS.Write(r.Data, 0, r.Len); sampleS.Write(Sep, 0, 3);
            }
            return;
        }
        Kept++; KeptBytes += r.Len;
        if (outS != null) {
            if (!firstOut) outS.Write(Sep, 0, 3);
            outS.Write(r.Data, 0, r.Len);
            firstOut = false;
        }
    }

    // Поля 0..9: дата, статус, {транзакция}, пользователь, компьютер, приложение, соединение,
    // событие, важность, "комментарий". Дальше разбирать не нужно.
    bool Parse(LgpRecord r) {
        byte[] d = r.Data; int p = 1, end = r.Len - 1;
        for (int f = 0; f <= 9; f++) {
            while (p < end && (d[p] == (byte)'\r' || d[p] == (byte)'\n')) p++;
            int s = p;
            if (p >= end) return false;
            if (d[p] == (byte)'{') {
                int dep = 0; bool q = false;
                for (; p < end; p++) {
                    if (d[p] == (byte)'"') q = !q;
                    else if (!q && d[p] == (byte)'{') dep++;
                    else if (!q && d[p] == (byte)'}' && --dep == 0) { p++; break; }
                }
            } else if (d[p] == (byte)'"') {
                p++;
                for (; p < end; p++) {
                    if (d[p] == (byte)'"') {
                        if (p + 1 < end && d[p + 1] == (byte)'"') { p++; continue; }
                        p++; break;
                    }
                }
            } else {
                while (p < end && d[p] != (byte)',') p++;
            }
            int e = p;
            switch (f) {
                case 0: r.Date = Num(d, s, e); break;
                case 1: r.Status = d[s]; break;
                case 2: r.Trx = Encoding.ASCII.GetString(d, s, e - s); break;
                case 6: r.Conn = Num(d, s, e); break;
                case 7: r.Event = (int)Num(d, s, e); break;
                case 8: r.Sev = d[s]; break;
                case 9:
                    if (DropEvents.Contains(r.Event) && (DropSev == 0 || r.Sev == DropSev)) {
                        r.Match = Prefix.Length == 0 || StartsWith(d, s + 1, e, Prefix);
                        if (r.Match) r.CommentHead = Head(d, s + 1, e);
                    }
                    break;
            }
            if (p < end && d[p] == (byte)',') p++;
        }
        return r.Date >= 19000101000000 && r.Event >= 0;
    }

    static long Num(byte[] d, int s, int e) {
        long v = 0;
        for (int i = s; i < e; i++) { int c = d[i] - '0'; if (c < 0 || c > 9) return -1; v = v * 10 + c; }
        return e > s ? v : -1;
    }

    static bool StartsWith(byte[] d, int s, int e, byte[] pre) {
        if (e - s < pre.Length) return false;
        for (int i = 0; i < pre.Length; i++) if (d[s + i] != pre[i]) return false;
        return true;
    }

    // Начало комментария до ", значение" — чтобы сгруппировать удаляемые записи по смыслу.
    static string Head(byte[] d, int s, int e) {
        int len = Math.Min(e - s, 400);
        if (len <= 0) return "";
        string t = Encoding.UTF8.GetString(d, s, len);
        int k = t.IndexOf(", значение", StringComparison.Ordinal);
        if (k > 0) t = t.Substring(0, k);
        else if (t.Length > 150) t = t.Substring(0, 150);
        return t.Replace("\r", " ").Replace("\n", " ");
    }
}
'@

if (-not ('LgpFilter' -as [type])) { Add-Type -TypeDefinition $source -Language CSharp }

# Словарь событий из .lgf: строки вида {4,"Имя",индекс}
$lgfText = [IO.File]::ReadAllText($Lgf, [Text.Encoding]::UTF8)
$events = @{}
foreach ($m in [regex]::Matches($lgfText, '\{4,"((?:[^"]|"")*)",(\d+)\}')) {
    $events[[int]$m.Groups[2].Value] = $m.Groups[1].Value.Replace('""', '"')
}
function Get-EventIndex([string]$name) {
    $hit = $events.GetEnumerator() | Where-Object Value -eq $name
    if (-not $hit) { throw "В $Lgf нет события '$name'. Точные имена — в stats.csv режима Stats." }
    [int]@($hit)[0].Key
}

$flt = [LgpFilter]::new()
# События транзакций нужны только для связывания; в словаре базы без откатов Rollback может не быть.
$flt.EvBegin = -1; $flt.EvRollback = -1
if ($LinkEmptyRollback) {
    $flt.EvBegin = Get-EventIndex '_$Transaction$_.Begin'
    $flt.EvRollback = Get-EventIndex '_$Transaction$_.Rollback'
}
foreach ($name in $DropEvent) { [void]$flt.DropEvents.Add((Get-EventIndex $name)) }
if ($DropSeverity) { $flt.DropSev = [byte][char]$DropSeverity }
$flt.Prefix = [Text.Encoding]::UTF8.GetBytes($CommentPrefix)
$flt.LinkTrx = [bool]$LinkEmptyRollback
$flt.MaxBytes = $MaxBytes; $flt.WindowSize = $Window; $flt.SampleCount = $SampleCount
Write-Host ("Правило: события [{0}], важность '{1}', префикс '{2}', связанные транзакции: {3}" -f
    (($DropEvent | ForEach-Object { "$_=" + (Get-EventIndex $_) }) -join '; '), $DropSeverity, $CommentPrefix, [bool]$LinkEmptyRollback)

if (-not $ReportDir) { $ReportDir = $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir, $ReportDir | Out-Null

$outFile = $null; $sampleFile = $null
if ($Mode -eq 'Filter') {
    $outFile = Join-Path $OutDir ([IO.Path]::GetFileName($Lgp))
    if (Test-Path $outFile) { throw "Файл $outFile уже есть — удалите его или выберите другой каталог" }
    if ((Resolve-Path $Lgp).Path -eq [IO.Path]::GetFullPath($outFile)) { throw 'Выходной файл совпадает с исходным' }
    $sampleFile = Join-Path $ReportDir 'removed-sample.txt'
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$flt.Run($Lgp, $outFile, $sampleFile)
$sw.Stop()

$rows = foreach ($kv in $flt.Stats.GetEnumerator()) {
    $k = $kv.Key.Split('|'); $v = $kv.Value
    [pscustomobject]@{
        EventIdx = [int]$k[0]; Event = $events[[int]$k[0]]; Severity = $k[1]; Status = $k[2]
        Records = $v[0]; MB = [math]::Round($v[1] / 1MB, 1)
        RemovedRecords = $v[2]; RemovedMB = [math]::Round($v[3] / 1MB, 1)
    }
}
$rows | Sort-Object MB -Descending | Export-Csv (Join-Path $ReportDir 'stats.csv') -NoTypeInformation -Encoding utf8BOM -Delimiter ';'
$flt.MatchHeads.GetEnumerator() | Sort-Object Value -Descending |
    Select-Object @{n = 'Count'; e = { $_.Value } }, @{n = 'CommentHead'; e = { $_.Key } } |
    Export-Csv (Join-Path $ReportDir 'matched-comments.csv') -NoTypeInformation -Encoding utf8BOM -Delimiter ';'

$report = @"
Режим:                 $Mode
Источник:              $Lgp
Прочитано байт:        $($flt.BytesRead.ToString('N0'))  (MaxBytes=$MaxBytes)
Период:                $($flt.FirstDate) .. $($flt.LastDate)
Записей всего:         $($flt.Total.ToString('N0'))
Оставлено:             $($flt.Kept.ToString('N0'))  ($([math]::Round($flt.KeptBytes / 1GB, 2)) ГБ)
Удалено:               $($flt.Removed.ToString('N0'))  ($([math]::Round($flt.RemovedBytes / 1GB, 2)) ГБ)
  записей по правилу:  $($flt.Matched.ToString('N0'))
  связанных транзакций: $($flt.LinkedTrx.ToString('N0'))
Нарушений структуры:   $($flt.Broken)
Время:                 $($sw.Elapsed)
Результат:             $outFile
"@
$report | Set-Content (Join-Path $ReportDir 'report.txt') -Encoding utf8BOM
Write-Host $report
Write-Host ''
$rows | Sort-Object MB -Descending | Select-Object -First 15 | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
