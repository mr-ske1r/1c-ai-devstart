# Загрузка расширения конфигурации из файла .cfe в базу с обновлением БД.
# ВНИМАНИЕ: полностью перезаписывает расширение в базе.
# Использование: load-cfe.ps1 <CFE_FILE> <EXT_NAME> [skipdbupdate]
#   CFE_FILE     — путь к файлу .cfe
#   EXT_NAME     — имя расширения в базе (если не существует — будет создано)
#   skipdbupdate — (опционально) пропустить обновление расширения в БД
# По умолчанию после загрузки выполняется обновление расширения в БД.
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$CfeFile,
	[Parameter(Mandatory, Position = 1)][string]$ExtName,
	[Parameter(Position = 2)][string]$Arg3
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$skipUpdate = ($Arg3 -ieq 'skipdbupdate')

Write-Host 'Загрузка расширения из файла...'
Write-Host "  Источник: $CfeFile"
Write-Host "  Расширение: $ExtName"

$upd = @()
if (-not $skipUpdate) {
	$upd = @('/UpdateDBCfg')
	Write-Host '  Обновление БД: да'
} else {
	Write-Host '  Обновление БД: нет'
}

$code = Invoke-Designer (@('/LoadCfg', $CfeFile, '-Extension', $ExtName) + $upd)

if ($code -eq 0) {
	Write-Host 'Загрузка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка загрузки'
	exit 1
}
