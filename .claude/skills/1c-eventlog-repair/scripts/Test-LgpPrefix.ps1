#Requires -Version 7
<#
.SYNOPSIS
  Самопроверка фильтра: файл холостого прогона Filter-1CLog.ps1 (без -DropEvent, обычно с -MaxBytes)
  обязан совпасть с началом исходного .lgp байт в байт и кончаться на границе записи.
.DESCRIPTION
  Сравнивает потоково, память не растет. Граница записи: в исходнике за последним байтом копии идет
  ",`r`n{" или конец файла. Код выхода 0 — совпало, 1 — расхождение (печатается смещение).
.EXAMPLE
  .\Test-LgpPrefix.ps1 -Source D:\log\20231107000000.lgp -Copy D:\work\dry\20231107000000.lgp
#>
param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Copy)

$src = @'
using System; using System.IO;
public static class LgpPrefix {
    // -1 — совпало; иначе смещение первого расхождения.
    public static long FirstDiff(string source, string copy) {
        using (var a = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1 << 16, FileOptions.SequentialScan))
        using (var b = new FileStream(copy, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan)) {
            if (b.Length > a.Length) return a.Length;
            byte[] ba = new byte[1 << 22], bb = new byte[1 << 22]; long pos = 0; int n;
            while ((n = b.Read(bb, 0, bb.Length)) > 0) {
                int got = 0;
                while (got < n) { int r = a.Read(ba, got, n - got); if (r <= 0) return pos + got; got += r; }
                for (int i = 0; i < n; i++) if (ba[i] != bb[i]) return pos + i;
                pos += n;
            }
            // Копия должна кончаться на границе записи: дальше в исходнике ",\r\n{" или конец файла.
            byte[] tail = new byte[4]; int t = 0, k;
            while (t < 4 && (k = a.Read(tail, t, 4 - t)) > 0) t += k;
            if (t == 0) return -1;
            if (t == 4 && tail[0] == ',' && tail[1] == '\r' && tail[2] == '\n' && tail[3] == '{') return -1;
            return pos;
        }
    }
}
'@
if (-not ('LgpPrefix' -as [type])) { Add-Type -TypeDefinition $src }

$len = (Get-Item -LiteralPath $Copy).Length
$diff = [LgpPrefix]::FirstDiff((Resolve-Path -LiteralPath $Source).Path, (Resolve-Path -LiteralPath $Copy).Path)
if ($diff -lt 0) {
    Write-Host ("СОВПАДАЕТ: {0:N0} байт копии равны началу исходника, конец — на границе записи" -f $len)
    exit 0
}
Write-Host ("РАСХОЖДЕНИЕ на смещении {0:N0} (длина копии {1:N0}) — фильтр портит данные, дальше не идти" -f $diff, $len)
exit 1
