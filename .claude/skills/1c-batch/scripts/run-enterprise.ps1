# Запуск 1С:Предприятие (неблокирующий).
# Использование: run-enterprise.ps1 [EPF_FILE]
#   EPF_FILE — (опционально) путь к обработке для автооткрытия
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Position = 0)][string]$EpfFile
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$arguments = @('ENTERPRISE') + (Get-IBArgs) + (Get-AuthArgs)
if ($EpfFile) {
	$arguments += @('/Execute', $EpfFile)
	Write-Host 'Запуск предприятия с обработкой...'
	Write-Host "  Обработка: $EpfFile"
} else {
	Write-Host 'Запуск предприятия...'
}

Start-Process -FilePath $ONEC_PATH -ArgumentList (ConvertTo-ArgString $arguments)
Write-Host 'Предприятие запущено'
exit 0
