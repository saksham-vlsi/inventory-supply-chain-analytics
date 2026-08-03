<#
  Inventory & Supply Chain Analytics -- end-to-end pipeline.

      .\run_pipeline.ps1

  build model -> quality gate -> inventory planning -> supplier analysis -> MySQL export
  Output: outputs\*.csv (22 marts) and outputs\mysql_load\ (bulk-load files)

  Idempotent -- rerun any time; it rebuilds from data\raw.
#>
param(
    [switch]$SkipDownload,
    [string]$DuckDb = ".\tools\duckdb.exe"
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# ---- 0. dependencies ---------------------------------------------------------
if (-not (Test-Path $DuckDb)) {
    Write-Host "DuckDB CLI not found - fetching portable binary..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path ".\tools" | Out-Null
    (New-Object System.Net.WebClient).DownloadFile(
        "https://github.com/duckdb/duckdb/releases/download/v1.5.5/duckdb_cli-windows-amd64.zip",
        ".\tools\duckdb.zip")
    Expand-Archive ".\tools\duckdb.zip" -DestinationPath ".\tools" -Force
    Remove-Item ".\tools\duckdb.zip" -Force
}

if (-not $SkipDownload -and -not (Test-Path ".\data\raw\scms_delivery_history.csv")) {
    Write-Host "Raw data missing - downloading..." -ForegroundColor Yellow
    & powershell -ExecutionPolicy Bypass -File ".\data\download_data.ps1"
}

New-Item -ItemType Directory -Force -Path ".\outputs\mysql_load" | Out-Null
$db = ".\outputs\inventory.duckdb"
if (Test-Path $db) { Remove-Item $db -Force }

# ---- 1..5 --------------------------------------------------------------------
$steps = @(
    @{ n = "1/5  Building model from both feeds"; f = "sql/01_build_model.sql"       },
    @{ n = "2/5  Data-quality gate";              f = "sql/02_data_quality.sql"      },
    @{ n = "3/5  Inventory planning parameters";  f = "sql/03_inventory_planning.sql"},
    @{ n = "4/5  Supplier analysis";              f = "sql/04_supplier_analysis.sql" },
    @{ n = "5/5  MySQL bulk-load export";         f = "sql/05_export_for_mysql.sql"  }
)
foreach ($s in $steps) {
    Write-Host ""
    Write-Host ("[{0}]" -f $s.n) -ForegroundColor Cyan
    & $DuckDb $db -c (".read {0}" -f $s.f)
    if ($LASTEXITCODE -ne 0) { throw "FAILED: $($s.f)" }
}

Write-Host ""
Write-Host "Pipeline complete. Published marts:" -ForegroundColor Green
Get-ChildItem ".\outputs" -Filter *.csv | Sort-Object Name |
    ForEach-Object { "   {0,-38} {1,9:N0} KB" -f $_.Name, ($_.Length / 1KB) }
Write-Host ""
Write-Host "For the relational implementation: sql\mysql\01_schema_and_load.sql" -ForegroundColor Green
