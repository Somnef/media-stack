$dest = "$env:USERPROFILE\Backups\media-stack"
$key  = "$env:USERPROFILE\.ssh\id_ed25519_plex"
$vm   = "somnef@192.168.1.16"

if (-not (Test-Connection 192.168.1.16 -Count 1 -Quiet)) { exit }

$remote = ssh -i $key $vm "ls -1 /home/somnef/backups/media-config-*.tar.gz 2>/dev/null"
foreach ($file in $remote) {
    if (-not $file) { continue }
    $name = Split-Path $file -Leaf
    scp -i $key "${vm}:$file" $dest
    if ($LASTEXITCODE -ne 0) { Write-Warning "scp failed for $name"; continue }
    $remoteSize = ssh -i $key $vm "stat -c %s '$file'"
    if ([int64]$remoteSize -eq (Get-Item (Join-Path $dest $name)).Length) {
        ssh -i $key $vm "rm -- '$file'"
    } else {
        Write-Warning "size mismatch for $name, keeping remote copy"
    }
}

Get-ChildItem $dest -Filter "media-config-*.tar.gz" |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 2 | Remove-Item -Force
