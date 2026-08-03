<#
  Downloads both raw feeds. Run once from the repository root:
      powershell -ExecutionPolicy Bypass -File .\data\download_data.ps1

  DEMAND FEED       Online Retail II -- UCI ML Repository (CC BY 4.0)
                    https://archive.ics.uci.edu/dataset/502/online+retail+ii
  PROCUREMENT FEED  SCMS Delivery History -- USAID (public domain)
                    https://data.usaid.gov/
#>
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dest  = Join-Path $PSScriptRoot "raw"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$root  = Split-Path $PSScriptRoot -Parent
$duck  = Join-Path $root "tools\duckdb.exe"
if (-not (Test-Path $duck)) { throw "tools\duckdb.exe not found - run .\run_pipeline.ps1 first, it fetches the engine." }

$wc = New-Object System.Net.WebClient

# ---- 1. Online Retail II ------------------------------------------------------
# The source ships as a two-sheet .xlsx, so it is converted to CSV here using
# the same portable engine the pipeline uses. Note InvoiceDate survives this as
# an Excel serial number -- sql/01_build_model.sql converts it to a timestamp.
$zip    = Join-Path $env:TEMP "online_retail_II.zip"
$unzip  = Join-Path $env:TEMP "or2"
Write-Host "  downloading Online Retail II (~45 MB) ..." -NoNewline
$wc.DownloadFile("https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip", $zip)
Expand-Archive $zip -DestinationPath $unzip -Force
Write-Host " done"

$xlsx = (Get-ChildItem $unzip -Filter *.xlsx -Recurse | Select-Object -First 1).FullName
$x = $xlsx -replace "\\","/"
$d = $dest -replace "\\","/"
Write-Host "  converting xlsx -> csv ..." -NoNewline
@"
INSTALL excel; LOAD excel;
COPY (SELECT * FROM read_xlsx('$x', sheet='Year 2009-2010')) TO '$d/online_retail_2009_2010.csv' (HEADER);
COPY (SELECT * FROM read_xlsx('$x', sheet='Year 2010-2011')) TO '$d/online_retail_2010_2011.csv' (HEADER);
"@ | & $duck | Out-Null
Write-Host " done"

# ---- 2. SCMS Delivery History -------------------------------------------------
Write-Host "  downloading SCMS delivery history ..." -NoNewline
$wc.DownloadFile(
  "https://media.githubusercontent.com/media/pandey-rakshit/data-library/main/FedEx/SCMS_Delivery_History_Dataset.csv",
  (Join-Path $dest "scms_delivery_history.csv"))
Write-Host " done"
$wc.Dispose()

Write-Host ""
Get-ChildItem $dest -Filter *.csv | ForEach-Object { "   {0,-40} {1,9:N0} KB" -f $_.Name, ($_.Length / 1KB) }
Write-Host ""
Write-Host "Raw data ready. Next: .\run_pipeline.ps1" -ForegroundColor Green
