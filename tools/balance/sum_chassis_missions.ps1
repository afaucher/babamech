# sum_chassis_missions.ps1 - summarise test_logs\balance\chassis\missions_<Tag>\*.json (run_chassis_missions.ps1) as
# markdown: one row per run name (chassis_loadout) over its seeds, plus a per-seed table.
#   .\tools\balance\sum_chassis_missions.ps1 -Tag base [-Ref strider_default]
param([string[]]$Tag = @("base"), [string]$Ref = "strider_default")
$root = Resolve-Path "$PSScriptRoot\..\.."
$runs = @{}
foreach ($t in $Tag) {
	foreach ($f in Get-ChildItem (Join-Path $root "test_logs\balance\chassis\missions_$t\*.json")) {
		$name = $f.BaseName -replace '_s\d+$', ''
		if ($Tag.Count -gt 1) { $name = "$t/$name" }
		$seed = [int]($f.BaseName -replace '^.*_s', '')
		$j = Get-Content -Raw $f.FullName | ConvertFrom-Json
		if (-not $runs.ContainsKey($name)) { $runs[$name] = @() }
		$runs[$name] += [PSCustomObject]@{ Seed = $seed; J = $j }
	}
}
function Sum-Obj($o) { $s = 0.0; if ($o) { foreach ($p in $o.PSObject.Properties) { $s += [double]$p.Value } }; return $s }
$lines = @("| run | seeds | won | mean win time s | deaths | dealt / min | taken / min | can't bear % | heat-held % | slot-dry % | TTK s (kills) | damage by hardpoint |",
	"|---|---|---|---|---|---|---|---|---|---|---|---|")
$per = @("| run | seed | outcome | time s | deaths | dealt/min | taken/min | can't bear % | heat-held % |", "|---|---|---|---|---|---|---|---|---|")
$summary = @{}
foreach ($name in ($runs.Keys | Sort-Object)) {
	$rs = $runs[$name] | Sort-Object Seed
	$won = 0; $time = 0.0; $deaths = 0; $dealt = 0.0; $taken = 0.0; $sight = 0.0; $off = 0.0; $hold = 0.0; $dry = 0.0
	$hp = @{}; $kills = @{}; $ttk = @{}; $slots = 0
	foreach ($r in $rs) {
		$j = $r.J
		if ($j.outcome -eq "won") { $won++ }
		$t = [double]$j.time; $time += $t; $deaths += [int]$j.deaths
		$d = Sum-Obj $j.hp_damage; $dealt += $d; $taken += [double]$j.taken
		$so = 0.0; $ss = 0.0
		foreach ($p in $j.bear.PSObject.Properties) { $ss += [double]$p.Value.sight; $so += [double]$p.Value.off }
		$sight += $ss; $off += $so; $hold += [double]$j.heat_hold_s
		$dry += (Sum-Obj $j.dry_s)
		$slots = [Math]::Max($slots, @($j.loadout.PSObject.Properties | Where-Object { $_.Value -ne "" }).Count)
		foreach ($p in $j.hp_damage.PSObject.Properties) { $hp[$p.Name] = [double]$hp[$p.Name] + [double]$p.Value }
		foreach ($p in $j.kills.PSObject.Properties) { $kills[$p.Name] = [int]$kills[$p.Name] + [int]$p.Value }
		foreach ($p in $j.ttk_sum.PSObject.Properties) { $ttk[$p.Name] = [double]$ttk[$p.Name] + [double]$p.Value }
		$per += "| $name | $($r.Seed) | $($j.outcome) | {0:N0} | $($j.deaths) | {1:N0} | {2:N0} | {3:N0} | {4:N0} |" -f $t, (60 * $d / $t), (60 * [double]$j.taken / $t), (100 * $so / [Math]::Max($ss, 0.001)), (100 * [double]$j.heat_hold_s / $t)
	}
	$n = $rs.Count
	$hpTot = ($hp.Values | Measure-Object -Sum).Sum
	$hps = ($hp.Keys | Sort-Object | ForEach-Object { "{0} {1:N0}%" -f $_, (100 * $hp[$_] / [Math]::Max($hpTot, 1)) }) -join ", "
	$tk = (@("turret", "turret_missile", "turret_sniper", "strider", "strider_breacher", "tank", "gunship", "trooper_rifle") | Where-Object { $kills[$_] } | ForEach-Object { "{0} {1:N1} ({2})" -f $_, ($ttk[$_] / $kills[$_]), $kills[$_] }) -join ", "
	$summary[$name] = @{ time = $time / $n; deaths = $deaths / $n; dpm = 60 * $dealt / $time; tpm = 60 * $taken / $time; won = $won; n = $n }
	$lines += "| $name | $n | $won | {0:N0} | {1:N1} | {2:N0} | {3:N0} | {4:N0} | {5:N0} | {6:N0} | $tk | $hps |" -f ($time / $n), ($deaths / $n), (60 * $dealt / $time), (60 * $taken / $time), (100 * $off / [Math]::Max($sight, 0.001)), (100 * $hold / $time), (100 * $dry / ($time * [Math]::Max($slots, 1)))
}
$lines += ""
if ($summary.ContainsKey($Ref)) {
	$b = $summary[$Ref]
	$lines += "| run | win time vs $Ref | dealt/min % | taken/min % | deaths |"
	$lines += "|---|---|---|---|---|"
	foreach ($name in ($summary.Keys | Sort-Object)) {
		$s = $summary[$name]
		$lines += "| $name | {0:N0}% | {1:N0}% | {2:N0}% | {3:N1} vs {4:N1} |" -f (100 * $s.time / $b.time), (100 * $s.dpm / $b.dpm), (100 * $s.tpm / $b.tpm), $s.deaths, $b.deaths
	}
}
$lines += ""
$lines += $per
$out = $lines -join "`n"
$out
Set-Content -Path (Join-Path $root ("test_logs\balance\chassis\missions_{0}.md" -f ($Tag -join "+"))) -Value $out -Encoding utf8
