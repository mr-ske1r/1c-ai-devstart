# Выгрузка расширения конфигурации из базы в файл .cfe.
# Использование: dump-cfe.ps1 <CFE_FILE> <EXT_NAME>
#   CFE_FILE — путь к результирующему файлу .cfe
#   EXT_NAME — имя расширения в базе
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$CfeFile,
	[Parameter(Mandatory, Position = 1)][string]$ExtName
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$outDir = Split-Path -Parent $CfeFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
	New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

Write-Host 'Выгрузка расширения в файл...'
Write-Host "  Результат: $CfeFile"
Write-Host "  Расширение: $ExtName"

$code = Invoke-Designer @('/DumpCfg', $CfeFile, '-Extension', $ExtName)

if ($code -eq 0) {
	Write-Host 'Выгрузка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка выгрузки'
	exit 1
}
