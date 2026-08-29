# Выгрузка основной конфигурации из базы в файл .cf.
# Использование: dump-cf.ps1 <CF_FILE>
#   CF_FILE — путь к результирующему файлу .cf
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$CfFile
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$outDir = Split-Path -Parent $CfFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
	New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

Write-Host 'Выгрузка конфигурации в файл...'
Write-Host "  Результат: $CfFile"

$code = Invoke-Designer @('/DumpCfg', $CfFile)

if ($code -eq 0) {
	Write-Host 'Выгрузка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка выгрузки'
	exit 1
}
