# --- 실행 환경 인코딩 설정 (가장 먼저 실행) ---
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

# --- 사용자 설정 영역 ---
$listenPort = 9309
$logFilePath = "C:\Users\ryuax\Documents\logs\wsl-portforwarding.txt"

# --- [개선] 지능적 대기를 위한 설정 ---
$maxRetries = 10              # 최대 시도 횟수
$retryIntervalSeconds = 5     # 시도 간 대기 시간 (초)

# --- 로깅 함수 ---
function Write-Log {
    param(
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $message"
    Add-Content -Path $logFilePath -Value $logEntry
    Write-Host $logEntry
}

# --- 스크립트 메인 로직 ---
Write-Log "--- 스크립트 실행 시작 ---"
$wslIp = $null

# --- [개선] WSL IP를 할당받을 때까지 대기하는 Retry Loop ---
for ($i = 1; $i -le $maxRetries; $i++) {
    Write-Log "WSL IP 주소 확인 시도 ($i/$maxRetries)..."
    $currentIp = (wsl hostname -I).Split(' ')[0].Trim()

    if ($currentIp) {
        Write-Log "WSL IP 주소 확인 성공: $currentIp"
        $wslIp = $currentIp
        break # IP를 찾았으므로 루프 탈출
    }

    if ($i -lt $maxRetries) {
        Write-Log "아직 IP가 할당되지 않았습니다. $retryIntervalSeconds초 후 다시 시도합니다."
        Start-Sleep -Seconds $retryIntervalSeconds
    }
}

# --- [개선] 최종적으로 IP를 할당받았는지 확인 ---
if (-not $wslIp) {
    Write-Log "[오류] 최대 시도 횟($maxRetries)을 초과했으나 WSL IP를 가져오지 못했습니다. 스크립트를 종료합니다."
    Start-Sleep -Seconds 5
    exit # 스크립트 종료
}

# --- IP 확인 후 포트 포워딩 로직 시작 ---
try {
    Write-Log "$listenPort 포트에 대한 기존 포트 포워딩 규칙을 삭제합니다..."
    netsh interface portproxy delete v4tov4 listenport=$listenPort listenaddress=0.0.0.0 | Out-Null
    Write-Log "기존 규칙 삭제 완료 (또는 삭제할 규칙 없음)."

    Write-Log "새로운 규칙을 추가합니다: 0.0.0.0\:$listenPort -> $wslIp\:$listenPort"
    netsh interface portproxy add v4tov4 listenport=$listenPort listenaddress=0.0.0.0 connectport=$listenPort connectaddress=$wslIp
    Write-Log "포트 포워딩 설정이 성공적으로 완료되었습니다."

} catch {
	$errorMessage = "[오류 발생] $($_.Exception.Message)" 
	Write-Log $errorMessage
	Write-EventLog -LogName "Application" -Source "WSL Port Forwarding Script" -EventId 1001 -EntryType Error -Message $errorMessage
} finally {
    Write-Log "--- 스크립트 실행 종료 ---`n"
}

Start-Sleep -Seconds 5