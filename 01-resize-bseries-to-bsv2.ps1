# GROUP A: B-series (v1) -> Bsv2 | In-place resize (PowerShell / Az module)
# Preserves OS + data disks and config. Downtime ~2-5 min per VM.
$RG = "myResourceGroup"
$Map = @{
  "vm-b4ms"  = "Standard_B4s_v2"
  "vm-b8ms"  = "Standard_B8s_v2"
  "vm-b1ms"  = "Standard_B2ls_v2"
  "vm-b1s"   = "Standard_B2ts_v2"
  "vm-b16ms" = "Standard_B16s_v2"
}
foreach ($vm in $Map.Keys) {
  $target = $Map[$vm]
  Write-Host "==> $vm -> $target"
  Stop-AzVM -ResourceGroupName $RG -Name $vm -Force
  $v = Get-AzVM -ResourceGroupName $RG -Name $vm
  $v.HardwareProfile.VmSize = $target
  Update-AzVM -ResourceGroupName $RG -VM $v
  Start-AzVM -ResourceGroupName $RG -Name $vm
}
