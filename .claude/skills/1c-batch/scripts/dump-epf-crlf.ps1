# Разборка внешней обработки/отчёта в XML (вариант с переносами CRLF).
# Использование: dump-epf-crlf.ps1 <XML_FILE> <EPF_FILE>
# Поведение идентично dump-epf.ps1 (сохранён для совместимости с .bat-набором).
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$XmlFile,
	[Parameter(Mandatory, Position = 1)][string]$EpfFile
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

Write-Host 'Разборка обработки...'
Write-Host "  Источник: $EpfFile"
Write-Host "  Результат: $XmlFile"

$code = Invoke-Designer @('/DumpExternalDataProcessorOrReportToFiles', $XmlFile, $EpfFile)

if ($code -eq 0) {
	Write-Host 'Разборка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка разборки'
	exit 1
}
