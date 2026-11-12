# Pulls contacts and opportunities from GoHighLevel (API v2) into raw JSON files.
# Reads GHL_TOKEN and GHL_LOCATION_ID from the environment (GitHub secrets), or from ../.env locally.
# Prints only counts, never the token.
param([string]$OutDir = ([IO.Path]::Combine($PSScriptRoot, '..', 'raw')))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')

$token = Get-Setting 'GHL_TOKEN'; $loc = Get-Setting 'GHL_LOCATION_ID'
if (-not $token -or -not $loc) { throw 'GHL_TOKEN and GHL_LOCATION_ID must be set (GitHub secrets, or the .env file locally).' }
$headers = @{ Authorization = "Bearer $token"; Version = '2021-07-28'; Accept = 'application/json' }
$base = 'https://services.leadconnectorhq.com'
New-Item -ItemType Directory -Force $OutDir | Out-Null

function Call($method, $path, $body) {
  $req = @{ Method = $method; Uri = "$base$path"; Headers = $headers; UseBasicParsing = $true }
  if ($body) { $req.Body = ($body | ConvertTo-Json -Depth 10); $req.ContentType = 'application/json' }
  for ($try = 0; $try -lt 4; $try++) {
    try { return Invoke-RestMethod @req }
    catch {
      $code = $null; if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      if ($code -eq 429 -and $try -lt 3) { Start-Sleep -Seconds (2 * ($try + 1)); continue }
      $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
      throw "GoHighLevel $method $($path.Split('?')[0]) failed: HTTP $code $msg"
    }
  }
}
function Save($obj, $name) { [IO.File]::WriteAllText((Join-Path $OutDir $name), (ConvertTo-Json -Depth 10 -Compress -InputObject $obj)) }

$pipes = Call GET "/opportunities/pipelines?locationId=$loc"
Save $pipes 'pipelines.json'

$opps = @(); $page = 1
do {
  $r = Call GET "/opportunities/search?location_id=$loc&limit=100&page=$page&status=all"
  $opps += @($r.opportunities); $page++
} while (@($r.opportunities).Count -eq 100 -and $page -lt 200)
Save @($opps | ForEach-Object { [pscustomobject]@{ id = $_.id; contactId = $_.contactId; pipelineId = $_.pipelineId; pipelineStageId = $_.pipelineStageId; status = $_.status; source = $_.source; monetaryValue = $_.monetaryValue; createdAt = $_.createdAt } }) 'opportunities.json'

# Email, phone and name are kept only as one-way hashes, used to spot duplicates. They never leave the raw folder.
$sha = [Security.Cryptography.SHA256]::Create()
function Hash([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') })
}
# Last 9 digits, so "+961 3 123 456" and "03 123 456" match; numbers shorter than 7 digits are ignored.
function PhoneKey($p) {
  $d = ([string]$p) -replace '\D', ''
  if ($d.Length -lt 7) { return $null }
  if ($d.Length -gt 9) { $d = $d.Substring($d.Length - 9) }
  $d
}

$contacts = @(); $page = 1
do {
  $r = Call POST '/contacts/search' @{ locationId = $loc; page = $page; pageLimit = 100 }
  $contacts += @($r.contacts | ForEach-Object {
    [pscustomobject]@{
      id = $_.id; dateAdded = $_.dateAdded; source = $_.source
      email_hash = (Hash (([string]$_.email).Trim().ToLower()))
      phone_hash = (Hash (PhoneKey $_.phone))
      name_hash = (Hash ((("$($_.firstName)$($_.lastName)") -replace '\s', '').ToLower()))
    }
  })
  $page++
} while (@($r.contacts).Count -eq 100 -and $page -lt 500)
Save @($contacts) 'contacts.json'

"pipelines: $(@($pipes.pipelines).Count)  opportunities: $($opps.Count)  contacts: $($contacts.Count)"
