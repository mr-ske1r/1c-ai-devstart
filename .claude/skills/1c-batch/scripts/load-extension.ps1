# Загрузка расширения конфигурации из XML в базу с обновлением БД.
# Использование: load-extension.ps1 <XML_DIR> <EXT_NAME> [skipdbupdate]
#   XML_DIR      — каталог с XML-файлами расширения
#   EXT_NAME     — имя расширения в базе (если не существует — будет создано)
#   skipdbupdate — (опционально) пропустить обновление расширения в БД
# По умолчанию после загрузки выполняется обновление расширения в БД.
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$XmlDir,
	[Parameter(Mandatory, Position = 1)][string]$ExtName,
	[Parameter(Position = 2)][string]$Arg3
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$skipUpdate = ($Arg3 -ieq 'skipdbupdate')

Write-Host 'Загрузка расширения...'
Write-Host "  Источник: $XmlDir"
Write-Host "  Расширение: $ExtName"

$upd = @()
if (-not $skipUpdate) {
	$upd = @('/UpdateDBCfg')
	Write-Host '  Обновление БД: да'
} else {
	Write-Host '  Обновление БД: нет'
}

$code = Invoke-Designer (@('/LoadConfigFromFiles', $XmlDir, '-Extension', $ExtName, '-updateConfigDumpInfo') + $upd)

if ($code -eq 0) {
	Write-Host 'Загрузка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка загрузки'
	exit 1
}
