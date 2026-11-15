#Requires -Version 7
<#
.SYNOPSIS
  Выписывает целиком записи .lgp по префиксу даты (ГГГГММДДччммсс, можно короче) и, при -Event, по номеру
  события из .lgf. Нужен, чтобы посмотреть конкретные записи, на которые указала платформа или БСП.
.EXAMPLE
  .\Grep-LgpRecords.ps1 -Lgp D:\log\20231107000000.lgp -DatePrefixes '2026050415','20260618125254' -Event 34
.NOTES
  Номер события фильтруется по подстроке ",<номер>,<важность>," — в комментариях бывают ложные совпадения,
  результат проверяй глазами. Читает файл целиком последовательно: 15 ГБ — пара минут.
#>
param([Parameter(Mandatory)][string]$Lgp, [Parameter(Mandatory)][string[]]$DatePrefixes, [int]$Event = -1, [int]$Max = 50)
$src = @'
using System; using System.Collections.Generic; using System.IO; using System.Text;
public static class LgpGrep {
    public static List<string> Run(string path, string[] prefixes, int ev, int max) {
        var res = new List<string>();
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1<<16, FileOptions.SequentialScan)) {
            byte[] buf = new byte[1<<23]; var rec = new MemoryStream(); bool q = false, inRec = false; int dep = 0, n; long off = 0, start = 0;
            while ((n = fs.Read(buf, 0, buf.Length)) > 0) {
                for (int i = 0; i < n; i++) {
                    byte b = buf[i];
                    if (!inRec) { if (b == '{') { inRec = true; dep = 1; q = false; rec.SetLength(0); rec.WriteByte(b); start = off + i; } continue; }
                    if (rec.Length < 4096) rec.WriteByte(b);
                    if (b == '"') q = !q;
                    else if (!q) { if (b == '{') dep++; else if (b == '}' && --dep == 0) {
                        inRec = false;
                        string head = Encoding.ASCII.GetString(rec.GetBuffer(), 1, 14);
                        foreach (var p in prefixes) if (head.StartsWith(p)) {
                            string t = Encoding.UTF8.GetString(rec.GetBuffer(), 0, (int)rec.Length);
                            if (ev < 0 || t.Contains("," + ev + ",I,") || t.Contains("," + ev + ",W,") || t.Contains("," + ev + ",E,") || t.Contains("," + ev + ",N,"))
                                res.Add("@" + start + "\r\n" + t);
                            break;
                        }
                        if (res.Count >= max) return res;
                    } }
                }
                off += n;
            }
        }
        return res;
    }
}
'@
if (-not ('LgpGrep' -as [type])) { Add-Type -TypeDefinition $src }
[LgpGrep]::Run($Lgp, $DatePrefixes, $Event, $Max)

