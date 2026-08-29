# Сборка внешней обработки/отчёта из XML.
# Использование: build-epf.ps1 <XML_FILE> <OUTPUT_FILE>
#   XML_FILE    — корневой XML-файл обработки
#   OUTPUT_FILE — путь к результирующему .epf/.erf
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$XmlFile,
	[Parameter(Mandatory, Position = 1)][string]$OutputFile
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$outDir = Split-Path -Parent $OutputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
	New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

Write-Host 'Сборка обработки...'
Write-Host "  Источник: $XmlFile"
Write-Host "  Результат: $OutputFile"

$code = Invoke-Designer @('/LoadExternalDataProcessorOrReportFromFiles', $XmlFile, $OutputFile)

if ($code -eq 0) {
	Write-Host 'Сборка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка сборки'
	exit 1
}
