# Загрузка основной конфигурации из файла .cf в базу с обновлением БД.
# ВНИМАНИЕ: полностью перезаписывает конфигурацию базы.
# Использование: load-cf.ps1 <CF_FILE> [skipdbupdate]
#   CF_FILE      — путь к файлу .cf
#   skipdbupdate — (опционально) пропустить обновление конфигурации БД
# По умолчанию после загрузки выполняется обновление конфигурации БД.
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$CfFile,
	[Parameter(Position = 1)][string]$Arg2
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$skipUpdate = ($Arg2 -ieq 'skipdbupdate')

Write-Host 'Загрузка конфигурации из файла...'
Write-Host "  Источник: $CfFile"

$upd = @()
if (-not $skipUpdate) {
	$upd = @('/UpdateDBCfg')
	Write-Host '  Обновление БД: да'
} else {
	Write-Host '  Обновление БД: нет'
}

$code = Invoke-Designer (@('/LoadCfg', $CfFile) + $upd)

if ($code -eq 0) {
	Write-Host 'Загрузка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка загрузки'
	exit 1
}
