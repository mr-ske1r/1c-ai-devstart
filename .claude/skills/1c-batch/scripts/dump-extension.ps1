# Выгрузка расширения конфигурации из базы в XML.
# Использование: dump-extension.ps1 <XML_DIR> <EXT_NAME> [update]
#   XML_DIR  — каталог для выгрузки XML
#   EXT_NAME — имя расширения в базе
#   update   — (опционально) инкрементальная выгрузка (только изменения)
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$XmlDir,
	[Parameter(Mandatory, Position = 1)][string]$ExtName,
	[Parameter(Position = 2)][string]$Mode
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

Write-Host 'Выгрузка расширения...'
Write-Host "  Результат: $XmlDir"
Write-Host "  Расширение: $ExtName"

$upd = @()
if ($Mode -ieq 'update') {
	$upd = @('-update')
	Write-Host '  Режим: инкрементальная'
} else {
	Write-Host '  Режим: полная'
}

$code = Invoke-Designer (@('/DumpConfigToFiles', $XmlDir, '-Extension', $ExtName) + $upd)

if ($code -eq 0) {
	Write-Host 'Выгрузка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка выгрузки'
	exit 1
}
