# Выгрузка конфигурации из базы в XML.
# Использование: dump-config.ps1 <XML_DIR> [update]
#   XML_DIR — каталог для выгрузки XML
#   update  — (опционально) инкрементальная выгрузка (только изменения)
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$XmlDir,
	[Parameter(Position = 1)][string]$Mode
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$dump = @()
if ($Mode -ieq 'update') {
	$dump = @('-update', '-force')
	Write-Host 'Инкрементальная выгрузка конфигурации...'
} else {
	Write-Host 'Полная выгрузка конфигурации...'
}
Write-Host "  Результат: $XmlDir"

$code = Invoke-Designer (@('/DumpConfigToFiles', $XmlDir) + $dump)

if ($code -eq 0) {
	Write-Host 'Выгрузка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка выгрузки'
	exit 1
}
