# Загрузка конфигурации из XML в базу с обновлением БД.
# Использование: load-config.ps1 <XML_DIR> [FILES] [skipdbupdate]
#   XML_DIR      — каталог с XML-файлами конфигурации
#   FILES        — (опционально) список файлов через запятую для частичной загрузки
#   skipdbupdate — (опционально) пропустить обновление конфигурации БД
# По умолчанию после загрузки выполняется обновление конфигурации БД.
# Требует .1c-devbase.ps1 в текущем каталоге.
param(
	[Parameter(Mandatory, Position = 0)][string]$XmlDir,
	[Parameter(Position = 1)][string]$Arg2,
	[Parameter(Position = 2)][string]$Arg3
)
. "$PSScriptRoot\_common.ps1"
. (Get-DevBasePath)

$files = ''
$skipUpdate = $false

# %2 может быть списком файлов ИЛИ "skipdbupdate"; %3 — только "skipdbupdate".
if ($Arg2 -ieq 'skipdbupdate') {
	$skipUpdate = $true
} elseif ($Arg2) {
	$files = $Arg2
}
if ($Arg3 -ieq 'skipdbupdate') {
	$skipUpdate = $true
}

$load = @()
if ($files) {
	$load = @('-files', $files, '-Format', 'Hierarchical')
	Write-Host 'Частичная загрузка конфигурации...'
	Write-Host "  Источник: $XmlDir"
	Write-Host "  Файлы: $files"
} else {
	Write-Host 'Полная загрузка конфигурации...'
	Write-Host "  Источник: $XmlDir"
}

$upd = @()
if (-not $skipUpdate) {
	$upd = @('/UpdateDBCfg')
	Write-Host '  Обновление БД: да'
} else {
	Write-Host '  Обновление БД: нет'
}

$code = Invoke-Designer (@('/LoadConfigFromFiles', $XmlDir) + $load + @('-updateConfigDumpInfo') + $upd)

if ($code -eq 0) {
	Write-Host 'Загрузка завершена успешно'
	exit 0
} else {
	Write-Host 'Ошибка загрузки'
	exit 1
}
