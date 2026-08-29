# Запуск конфигуратора 1С (неблокирующий).
# Использование: run-designer.ps1
# Требует .1c-devbase.ps1 в текущем каталоге.
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$arguments = @('DESIGNER') + (Get-IBArgs) + (Get-AuthArgs)

Write-Host 'Запуск конфигуратора...'
Start-Process -FilePath $ONEC_PATH -ArgumentList (ConvertTo-ArgString $arguments)
Write-Host 'Конфигуратор запущен'
exit 0
