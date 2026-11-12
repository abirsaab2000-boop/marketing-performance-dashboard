# Turns the raw GoHighLevel pull into the public data files the site reads (site/data).
# Keeps no names, emails, phone numbers or record ids: only dates, sources, stages, statuses and deal values.
#
# Data checks applied every run:
# - Duplicate contacts: contacts sharing an email or phone count as one lead, credited to the earliest one's source.
# - Unusually high deal values: more than 10x the median deal value in the pipeline. Kept in counts, left out of revenue, listed for checking.
# - Zero-value deals, deals marked Won outside the Closed stage, missing sources, same-name contacts: counted as-is and listed for checking.
param(
  [string]$RawDir = ([IO.Path]::Combine($PSScriptRoot, '..', 'raw')),
  [string]$OutDir = ([IO.Path]::Combine($PSScriptRoot, '..', 'site', 'data')),
  [datetime]$Today = [datetime]::UtcNow.Date
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')
New-Item -ItemType Directory -Force $OutDir | Out-Null
function Load($name) { @((Get-Content (Join-Path $RawDir $name) -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) }
function Save($rows, $name) { [IO.File]::WriteAllText((Join-Path $OutDir $name), (ConvertTo-Json -Compress -Depth 5 -InputObject $rows)) }
function Src($s) { if ([string]::IsNullOrWhiteSpace($s)) { 'No source recorded' } else { $s.Trim() } }
# PowerShell 7 turns ISO strings into dates when reading JSON; accept either.
function Stamp($v) { if ($v -is [datetime]) { $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') } else { [string]$v } }
function Day($v) { (Stamp $v).Substring(0, 10) }

$pipelineName = Get-Setting 'GHL_PIPELINE_NAME'; if (-not $pipelineName) { $pipelineName = 'Sales Pipeline' }
$paidStart = Get-Setting 'PAID_START_DATE'

$pipes = (Get-Content (Join-Path $RawDir 'pipelines.json') -Raw | ConvertFrom-Json).pipelines
$pipe = $pipes | Where-Object { $_.name -eq $pipelineName } | Select-Object -First 1
if (-not $pipe) { throw "Pipeline '$pipelineName' not found in GoHighLevel" }
$stageName = @{}; $stages = @()
foreach ($s in $pipe.stages) { $stageName[$s.id] = $s.name; $stages += [pscustomobject]@{ position = [int]$s.position; stage = $s.name } }

# Last full Monday-to-Sunday week before today
$dow = [int]$Today.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
$lwStart = $Today.AddDays(-($dow - 1) - 7); $lwEnd = $lwStart.AddDays(6)
$allStart = if ($paidStart) { [datetime]::ParseExact($paidStart, 'yyyy-MM-dd', $null) } else { $lwStart.AddDays(-7 * 12) }

# ---------- Contacts: merge duplicates (same email or same phone) ----------
$contacts = @(Load 'contacts.json' | Sort-Object { Stamp $_.dateAdded })
$owner = @{}; $kept = @(); $merged = 0
foreach ($c in $contacts) {
  $keys = @(); if ($c.email_hash) { $keys += 'e' + $c.email_hash }; if ($c.phone_hash) { $keys += 'p' + $c.phone_hash }
  $first = $keys | Where-Object { $owner.ContainsKey($_) } | Select-Object -First 1
  if ($first) { $merged++; $keys | ForEach-Object { if (-not $owner.ContainsKey($_)) { $owner[$_] = $owner[$first] } } }
  else { $kept += $c; $keys | ForEach-Object { $owner[$_] = $c.id } }
}
$leads = $kept | Group-Object { (Day $_.dateAdded) + '|' + (Src $_.source) } | ForEach-Object {
  $d, $s = $_.Name.Split('|', 2); [pscustomobject]@{ day = $d; source = $s; leads = $_.Count }
} | Sort-Object day, source

# ---------- Deals ----------
$rawDeals = @(Load 'opportunities.json' | Where-Object { $_.pipelineId -eq $pipe.id })
$positive = @($rawDeals | ForEach-Object { [double]($_.monetaryValue -as [double]) } | Where-Object { $_ -gt 0 } | Sort-Object)
$median = if ($positive.Count) { $positive[[int][math]::Floor(($positive.Count - 1) / 2)] } else { 0 }
$highAt = 10 * $median
$deals = $rawDeals | ForEach-Object {
  $v = [double]($_.monetaryValue -as [double])
  $check = if ($v -le 0) { 'no_value' } elseif ($median -gt 0 -and $v -gt $highAt) { 'unusually_high' } else { $null }
  [pscustomobject]@{
    created_day = (Day $_.createdAt); source = (Src $_.source)
    stage = $stageName[$_.pipelineStageId]; status = $_.status; value = $v; value_check = $check
  }
} | Sort-Object created_day, source, stage

# ---------- Data checks for the "Needs checking" panel ----------
$pipeContacts = @{}; $rawDeals | ForEach-Object { if ($_.contactId) { $pipeContacts[$_.contactId] = 1 } }
$nameGroups = @($kept | Where-Object { $_.name_hash } | Group-Object name_hash | Where-Object { $_.Count -gt 1 -and ($_.Group | Where-Object { $pipeContacts[$_.id] }) })
$item = { param($d) [pscustomobject]@{ value = $d.value; stage = $d.stage; status = $d.status; source = $d.source; created_day = $d.created_day } }
$checks = [pscustomobject]@{
  duplicates_merged = $merged
  same_name_groups = $nameGroups.Count
  same_name_contacts = ($nameGroups | Measure-Object Count -Sum).Sum -as [int]
  missing_source_contacts = @($kept | Where-Object { [string]::IsNullOrWhiteSpace($_.source) }).Count
  missing_source_deals = @($deals | Where-Object { $_.source -eq 'No source recorded' }).Count
  median_value = $median
  high_value_threshold = $highAt
  high_value_deals = @($deals | Where-Object { $_.value_check -eq 'unusually_high' } | ForEach-Object { & $item $_ })
  no_value_deals = @($deals | Where-Object { $_.value_check -eq 'no_value' }).Count
  no_value_closed = @($deals | Where-Object { $_.value_check -eq 'no_value' -and $_.stage -eq 'Closed' }).Count
  won_not_closed = @($deals | Where-Object { $_.status -eq 'won' -and $_.stage -ne 'Closed' } | ForEach-Object { & $item $_ })
}

$firstDay = (@($leads.day) + @($deals.created_day) | Sort-Object | Select-Object -First 1)
$report = [pscustomobject]@{
  generated_at = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); pipeline = $pipe.name
  last_week_start = $lwStart.ToString('yyyy-MM-dd'); last_week_end = $lwEnd.ToString('yyyy-MM-dd')
  four_weeks_start = $lwStart.AddDays(-21).ToString('yyyy-MM-dd')
  all_start = $allStart.ToString('yyyy-MM-dd'); paid_start_known = [bool]$paidStart
  data_first_day = $firstDay
}
Save @($report) 'report.json'; Save @($leads) 'leads_daily.json'; Save @($deals) 'deals.json'; Save @($stages | Sort-Object position) 'stages.json'; Save $checks 'checks.json'
"leads rows: $(@($leads).Count)  deals: $(@($deals).Count)  duplicates merged: $merged  high-value deals: $($checks.high_value_deals.Count) (over $highAt)  last week: $($report.last_week_start)..$($report.last_week_end)"
if (@($deals).Count -eq 0) { throw "No deals found in '$pipelineName'; not publishing an empty dashboard." }
