# Общие функции для PowerShell-скриптов навыка 1c-batch.
#
# ВАЖНО (Windows PowerShell 5.1): файлы .ps1 с кириллицей хранить в UTF-8 С BOM.
# Без BOM 5.1 читает .ps1 как ANSI (Windows-1251) и портит кириллицу — проверено.
# Это и есть причина перехода с .bat (cmd под chcp 65001 ненадёжно читает UTF-8).

$ErrorActionPreference = 'Stop'

# UTF-8 для вывода и пайпов: корректное чтение лога конфигуратора (/Out) и кириллицы.
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-DevBasePath {
	# Путь к настроечному файлу .1c-devbase.ps1.
	# Ищется в корне проекта, затем в подпапке tools\ (чтобы не засорять корень).
	# Дот-сорсить результат в вызывающем скрипте: . (Get-DevBasePath)
	$candidates = @(
		(Join-Path (Get-Location) '.1c-devbase.ps1'),
		(Join-Path (Get-Location) 'tools\.1c-devbase.ps1')
	)
	foreach ($p in $candidates) {
		if (Test-Path -LiteralPath $p) { return $p }
	}
	Write-Host 'Ошибка: не найден .1c-devbase.ps1 (искал в корне проекта и в tools\)'
	Write-Host 'Скопируйте .1c-devbase.ps1.example как .1c-devbase.ps1 (в корень проекта или в tools\) и заполните'
	exit 1
}

function Get-IBArgs {
	# Параметры подключения к ИБ. Приоритет — серверная база.
	if ($ONEC_SERVER) {
		return @('/S', "$ONEC_SERVER\$ONEC_BASE")
	} elseif ($ONEC_FILEBASE_PATH) {
		return @('/F', $ONEC_FILEBASE_PATH)
	} else {
		Write-Host 'Ошибка: не указан ни сервер (ONEC_SERVER), ни путь к файловой базе (ONEC_FILEBASE_PATH)'
		exit 1
	}
}

function Get-AuthArgs {
	# Параметры авторизации (пустые — опускаются).
	$a = @()
	if ($ONEC_USER)     { $a += "/N$ONEC_USER" }
	if ($ONEC_PASSWORD) { $a += "/P$ONEC_PASSWORD" }
	return ,$a
}

function Format-ArgList {
	# Массив с квотированием элементов, содержащих пробелы.
	# Для Start-Process -NoNewWindow (CreateProcess) — корректно передаёт кириллицу.
	param([Parameter(Mandatory)][string[]]$Items)
	return ($Items | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
}

function ConvertTo-ArgString {
	# Единая строка аргументов с квотированием пробелов.
	# Нужна для НЕблокирующего Start-Process (без -NoNewWindow), который идёт через
	# ShellExecute: передача массива там может испортить кириллицу — строка безопасна.
	param([Parameter(Mandatory)][string[]]$Items)
	return ((Format-ArgList $Items) -join ' ')
}

function Invoke-Designer {
	# Запуск конфигуратора в ПАКЕТНОМ (блокирующем) режиме. Возвращает код возврата.
	#
	# Используется Start-Process -NoNewWindow -Wait -PassThru (а НЕ оператор '&'):
	#   * '&' для GUI-приложения 1cv8.exe не дожидается завершения (отсоединяется),
	#     $LASTEXITCODE при этом мусорный, а недождавшийся конфигуратор блокирует базу;
	#   * -NoNewWindow использует CreateProcess (не ShellExecute) — массив аргументов
	#     передаётся без порчи кириллицы.
	# Диагностика конфигуратора пишется в /Out лог и выводится в консоль.
	param([Parameter(Mandatory)][string[]]$CommandArgs)

	$tempDir = Join-Path $env:TEMP ("1cbatch_" + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
	try {
		$outFile = Join-Path $tempDir 'designer.log'
		$all = @('DESIGNER') + (Get-IBArgs) + (Get-AuthArgs) + @('/DisableStartupDialogs') + $CommandArgs + @('/Out', $outFile)
		$proc = Start-Process -FilePath $ONEC_PATH -ArgumentList (Format-ArgList $all) -NoNewWindow -Wait -PassThru
		if (Test-Path $outFile) {
			$log = (Get-Content $outFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
			if ($log) {
				Write-Host '--- Лог конфигуратора ---'
				Write-Host $log.TrimEnd()
				Write-Host '--- Конец лога ---'
			}
		}
		return $proc.ExitCode
	} finally {
		if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
	}
}
