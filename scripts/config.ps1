# Settings come from environment variables first (GitHub secrets), then from ../.env (local runs).
$script:dotEnv = @{}
$envFile = [IO.Path]::Combine($PSScriptRoot, '..', '.env')
if (Test-Path $envFile) {
  Get-Content $envFile | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$' } | ForEach-Object { $script:dotEnv[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
function Get-Setting([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrWhiteSpace($v)) { $v = $script:dotEnv[$name] }
  # Drop stray invisible characters (byte-order marks, line breaks) picked up when a secret was pasted or piped.
  if ($v) { $v = $v -replace '[^\x20-\x7E]', '' }
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  return $v.Trim()
}
