#Requires -Version 7
<#
.SYNOPSIS
  Структурная диагностика .lgp старого формата: число полей в записях, места, где дата идёт назад,
  нечисловые ссылки и номера, которых нет в .lgf; с -Watch — выписка 40 записей начиная с заданной даты.
.DESCRIPTION
  Норма для живого журнала: 19 полей у обычных записей, 20–24 у «Отказа в доступе» (_$Access$_.AccessDenied
  дописывает числа после номера сеанса), единичные «даты назад» на секунды–минуты (параллельная запись).
  Ограничение: разбор .lgf построчный, многострочные элементы словаря (виды 11–13) не учитываются;
  виды 1–8, которые проверяются, однострочные.
.EXAMPLE
  .\Diag-Lgp.ps1 -Lgp D:\log\20231107000000.lgp -Lgf D:\log\1Cv8.lgf -Out D:\work\diag.txt -Watch 20260625065821
#>
param([Parameter(Mandatory)][string]$Lgp, [Parameter(Mandatory)][string]$Lgf, [Parameter(Mandatory)][string]$Out, [long]$Watch = 0)
$src = @'
using System; using System.Collections.Generic; using System.IO; using System.Text;
public class LgpDiag {
    public HashSet<long>[] Known = new HashSet<long>[16];
    public long Total, BackDates, Broken; public long LastDate;
    public Dictionary<int,long> FieldCounts = new Dictionary<int,long>();
    public List<string> Notes = new List<string>();
    public Dictionary<string,long> Missing = new Dictionary<string,long>();
    public long Watch;
    long pos; int watchLeft;
    int[] kindOfField = { 0,0,0,1,2,3,0,4,0,0,5,0,0,6,7,8 };
    public void Run(string path) {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1<<16, FileOptions.SequentialScan)) {
            byte[] buf = new byte[1<<23]; byte[] rec = new byte[1<<16]; int rl = 0;
            bool q = false, inRec = false; int dep = 0; long recStart = 0; int n; long baseOff = 0;
            while ((n = fs.Read(buf, 0, buf.Length)) > 0) {
                for (int i = 0; i < n; i++) {
                    byte b = buf[i];
                    if (!inRec) { if (b == '{') { inRec = true; dep = 1; q = false; rl = 0; recStart = baseOff + i; Add(ref rec, ref rl, b); } continue; }
                    Add(ref rec, ref rl, b);
                    if (b == '"') q = !q;
                    else if (!q) { if (b == '{') dep++; else if (b == '}' && --dep == 0) { inRec = false; pos = recStart; OnRec(rec, rl); } }
                }
                baseOff += n;
                if (baseOff % (10L<<30) < n) Console.WriteLine("  {0:N0} ГБ, записей {1:N0}", baseOff >> 30, Total);
            }
        }
    }
    static void Add(ref byte[] r, ref int l, byte b) { if (l == r.Length) Array.Resize(ref r, r.Length*2); r[l++] = b; }
    void Note(string s) { if (Notes.Count < 3000) Notes.Add(s); }
    void OnRec(byte[] d, int len) {
        Total++;
        var f = new List<string>(); int p = 1, end = len - 1;
        while (p < end) {
            while (p < end && (d[p]=='\r'||d[p]=='\n')) p++;
            int s = p;
            if (d[p]=='{') { int dp=0; bool q=false; for (; p<end; p++) { if (d[p]=='"') q=!q; else if(!q&&d[p]=='{') dp++; else if(!q&&d[p]=='}'&&--dp==0){p++;break;} } }
            else if (d[p]=='"') { p++; for (; p<end; p++) if (d[p]=='"') { if (p+1<end&&d[p+1]=='"'){p++;continue;} p++; break; } }
            else while (p<end && d[p]!=',') p++;
            f.Add(Encoding.UTF8.GetString(d, s, Math.Min(p - s, 200)));
            while (p<end && (d[p]=='\r'||d[p]=='\n')) p++;
            if (p<end && d[p]==',') p++;
        }
        long c; FieldCounts.TryGetValue(f.Count, out c); FieldCounts[f.Count] = c + 1;
        long date; long.TryParse(f.Count > 0 ? f[0] : "", out date);
        if (f.Count < 19 || f.Count > 24) { Broken++; Note("ПОЛЯ " + f.Count + " @" + pos + ": " + Encoding.UTF8.GetString(d, 0, Math.Min(len, 600))); }
        if (date < LastDate) { BackDates++; Note("ДАТА НАЗАД @" + pos + ": " + LastDate + " -> " + date); }
        if (Watch > 0 && date == Watch) watchLeft = 40;
        if (watchLeft > 0) { watchLeft--; Note("WATCH @" + pos + " len " + len + ": " + Encoding.UTF8.GetString(d, 0, Math.Min(len, 3000))); }
        if (date > 0) LastDate = date;
        for (int i = 3; i < 16 && i < f.Count; i++) {
            int k = kindOfField[i]; if (k == 0) continue;
            long v; if (!long.TryParse(f[i], out v)) { Note("НЕ ЧИСЛО поле " + i + " @" + pos + ": " + f[i]); continue; }
            if (v == 0) continue;
            if (!Known[k].Contains(v)) {
                string key = "вид " + k + " индекс " + v; long m; Missing.TryGetValue(key, out m);
                if (m == 0) Note("НЕТ В LGF " + key + " @" + pos + " дата " + date);
                Missing[key] = m + 1;
            }
        }
    }
}
'@
if (-not ('LgpDiag' -as [type])) { Add-Type -TypeDefinition $src }
$diag = [LgpDiag]::new(); $diag.Watch = $Watch
for ($i = 0; $i -lt 16; $i++) { $diag.Known[$i] = [Collections.Generic.HashSet[long]]::new() }
$t = [IO.File]::ReadAllText($Lgf)
foreach ($m in [regex]::Matches($t, '(?m)^\{(\d+),.*?,(\d+)\},?\r?$')) {
    $k = [int]$m.Groups[1].Value; if ($k -lt 16) { [void]$diag.Known[$k].Add([long]$m.Groups[2].Value) }
}
1..8 | % { "lgf вид $_ : $($diag.Known[$_].Count) индексов" }
$sw = [Diagnostics.Stopwatch]::StartNew()
$diag.Run($Lgp)
$res = @("Записей: $($diag.Total)  время $($sw.Elapsed)", "Дат назад: $($diag.BackDates)", "Нестандартное число полей: $($diag.Broken)",
    "Поля: " + (($diag.FieldCounts.GetEnumerator() | % { "$($_.Key)=$($_.Value)" }) -join ', '),
    '--- Нет в lgf:') + ($diag.Missing.GetEnumerator() | % { "$($_.Key): $($_.Value)" }) + '--- Заметки:' + $diag.Notes
$res | Set-Content $Out -Encoding utf8BOM
$res | Select-Object -First 80


