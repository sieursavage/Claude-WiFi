# Read-only Wi-Fi diagnostic for Windows (PowerShell 5+).
# It changes no settings. It sends test traffic (speed test, pings) and reads system state.
# Usage:  powershell -ExecutionPolicy Bypass -File .\wifi-diag.ps1   -> writes wifi-report.txt
$Out = "wifi-report.txt"
Start-Transcript -Path $Out -Force | Out-Null
function HR($t) { Write-Output "`n========== $t ==========" }

HR "SYSTEM"; Get-Date; (Get-CimInstance Win32_OperatingSystem).Caption

$route = Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1
$GW = $route.NextHop
Write-Output "Default gateway: $GW   Interface: $($route.InterfaceAlias)"

HR "CURRENT WI-FI LINK (band, channel, signal, link speed)"
netsh wlan show interfaces
Get-NetAdapter | Where-Object Status -eq Up | Format-Table Name, InterfaceDescription, LinkSpeed -AutoSize | Out-String

HR "WI-FI DRIVER"
netsh wlan show drivers | Select-String "Driver|Version|Radio types|Wireless Display"

HR "NEARBY NETWORKS"
netsh wlan show networks mode=bssid

HR "NETWORKS PER CHANNEL"
netsh wlan show networks mode=bssid | Select-String "Channel\s+:\s+(\d+)" |
  ForEach-Object { $_.Matches[0].Groups[1].Value } | Group-Object | Sort-Object Count -Descending |
  Format-Table @{n='Channel';e={$_.Name}}, Count -AutoSize | Out-String

HR "LATENCY (20 pings each)"
foreach ($t in @($GW, "1.1.1.1", "8.8.8.8")) {
  if (-not $t) { continue }
  Write-Output "-- $t"
  ping -n 20 $t | Select-Object -Last 4
}

HR "SPEED TEST (Cloudflare, 100 MB down / 25 MB up)"
$d = & curl.exe -s -o NUL -w "%{speed_download}" "https://speed.cloudflare.com/__down?bytes=100000000"
$tmp = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllBytes($tmp, (New-Object byte[] 25000000))
$u = & curl.exe -s -o NUL -w "%{speed_upload}" --data-binary "@$tmp" "https://speed.cloudflare.com/__up"
Remove-Item $tmp
"Download: {0:N1} Mbps" -f ([double]$d * 8 / 1e6)
"Upload:   {0:N1} Mbps" -f ([double]$u * 8 / 1e6)

HR "WHAT IS USING THE NETWORK ON THIS PC"
Write-Output "Total adapter throughput (5-second sample):"
Get-Counter '\Network Interface(*)\Bytes Total/sec' -SampleInterval 5 -MaxSamples 1 |
  Select-Object -ExpandProperty CounterSamples | Where-Object CookedValue -gt 0 |
  Format-Table InstanceName, @{n='Mbps';e={[math]::Round($_.CookedValue*8/1e6,2)}} -AutoSize | Out-String
Write-Output "Processes with the most open connections:"
Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Group-Object OwningProcess |
  Sort-Object Count -Descending | Select-Object -First 20 |
  ForEach-Object { [pscustomobject]@{ Process = (Get-Process -Id $_.Name -ErrorAction SilentlyContinue).ProcessName; PID = $_.Name; Connections = $_.Count } } |
  Format-Table -AutoSize | Out-String
Write-Output "Processes with the highest I/O rate (includes disk):"
Get-Counter '\Process(*)\IO Data Bytes/sec' -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty CounterSamples | Where-Object { $_.InstanceName -notin '_total','idle' } |
  Sort-Object CookedValue -Descending | Select-Object -First 15 |
  Format-Table InstanceName, @{n='KB/s';e={[math]::Round($_.CookedValue/1KB,1)}} -AutoSize | Out-String

HR "DEVICES ON THE NETWORK"
if ($GW) {
  $prefix = $GW.Substring(0, $GW.LastIndexOf('.'))
  Write-Output "Pinging $prefix.1-254 to populate the ARP table..."
  $pings = 1..254 | ForEach-Object { (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$prefix.$_", 500) }
  try { [Threading.Tasks.Task]::WaitAll($pings) } catch {}
}
Get-NetNeighbor -AddressFamily IPv4 | Where-Object { $_.State -ne 'Unreachable' -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and $_.LinkLayerAddress -ne 'FF-FF-FF-FF-FF-FF' } |
  ForEach-Object {
    $name = try { [Net.Dns]::GetHostEntry($_.IPAddress).HostName } catch { "" }
    [pscustomobject]@{ IP = $_.IPAddress; MAC = $_.LinkLayerAddress; Name = $name; State = $_.State }
  } | Sort-Object { [version]$_.IP } | Format-Table -AutoSize | Out-String

HR "DONE"
Write-Output "Report saved to $Out. Paste its contents back to Claude."
Stop-Transcript | Out-Null
