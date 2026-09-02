# Прогон всех тестов приложения.
#   .\run_tests.ps1
#
# Два движка:
#   dart test test/pure   - быстрые unit-тесты чистой логики (без Flutter)
#   flutter test          - остальное (SharedPreferences, HTTP-моки, виджеты)
#
# Примечание: в некоторых песочницах `flutter test` не стартует
# (WebSocket listener блокируется, HTTP 403). На обычной машине разработчика и
# в CI всё проходит. `dart test test/pure` работает везде.

$ErrorActionPreference = "Stop"
$failed = $false

Write-Host "=== 1/2  dart test test/pure  (чистая логика) ===" -ForegroundColor Cyan
dart test test/pure
if ($LASTEXITCODE -ne 0) { $failed = $true }

Write-Host ""
Write-Host "=== 2/2  flutter test  (сервисы + виджеты) ===" -ForegroundColor Cyan
flutter test
if ($LASTEXITCODE -ne 0) { $failed = $true }

Write-Host ""
if ($failed) {
    Write-Host "ЕСТЬ ПАДЕНИЯ" -ForegroundColor Red
    exit 1
} else {
    Write-Host "ВСЁ ЗЕЛЁНОЕ" -ForegroundColor Green
    exit 0
}
