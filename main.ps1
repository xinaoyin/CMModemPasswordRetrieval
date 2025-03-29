function Clear-Console {
    $Host.UI.RawUI.Clear()
}

function Get-ValueFromText {
    param (
        [string]$Text
    )

    $linesToReturn = @()

    if (-not $Text) {
        return $linesToReturn
    }

    # 正则表达式匹配以 "get success!value=" 开头的行
    $pattern = '^get success!value=.*$'

    # 将输入的文本按行处理
    $Text -split "`r`n" | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -match $pattern) {
            $linesToReturn += $line
        }
    }

    return $linesToReturn
}

class ModemManager {
    [string]$HostAddress
    [int]$Port
    [string]$MacAddress
    [string]$Method

    ModemManager() {
        $this.HostAddress = ""
        $this.Port = 23
        $this.MacAddress = ""
        $this.Method = ""
    }

    [string]GetDefaultGateway() {
        try {
            $ipConfigOutput = Invoke-Expression "ipconfig" | Out-String
        }
        catch {
            Write-Host "Failed to execute ipconfig. Error: $_"
            return $null
        }

        if (-not $ipConfigOutput) {
            Write-Host "Failed to obtain network configuration."
            return $null
        }

        # 正则表达式匹配默认网关（考虑中文和英文输出）
        $pattern = '默认网关|Default Gateway'
        $gatewayPattern = '\b((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'

        $matches = [regex]::Matches($ipConfigOutput, "(?:$pattern)\s*:\s*$gatewayPattern")

        if ($matches.Count -gt 0) {
            # 优先选择IPv4地址
            foreach ($match in $matches) {
                $gateway = $match.Groups[1].Value
                if ($gateway -match '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$') {
                    $this.HostAddress = $gateway
                    Write-Host "Default Gateway obtained: $($this.HostAddress)"
                    return $this.HostAddress
                }
            }
            # 如果没有找到IPv4地址，返回第一个匹配的网关
            $this.HostAddress = $matches[0].Groups[1].Value
            Write-Host "Default Gateway obtained: $($this.HostAddress)"
            return $this.HostAddress
        }
        else {
            Write-Host "Failed to obtain Default Gateway from ipconfig output."
            return $null
        }
    }

    [string]GetMacAddress() {
        try {
            $arpResult = Invoke-Expression "arp -a" | Out-String
        }
        catch {
            Write-Host "Failed to obtain ARP table. Error: $_"
            return $null
        }

        if (-not $arpResult) {
            Write-Host "Failed to obtain ARP table."
            return $null
        }

        $lines = $arpResult -split "`r`n"
        $this.MacAddress = $null

        foreach ($line in $lines) {
            $line = $line.Trim()
            if ($line -match "$($this.HostAddress)\s+" -and $line -notmatch "---") {
                $fields = $line -split '\s+'
                if ($fields.Count -lt 3) {
                    Write-Host "Invalid ARP table entry: $line"
                    return $null
                }

                $this.MacAddress = $fields | Where-Object { $_ -match '-' } | Select-Object -First 1
                break
            }
        }

        if (-not $this.MacAddress) {
            Write-Host "Failed to obtain MAC address."
            return $null
        }

        $this.MacAddress = $this.MacAddress.ToUpper().Replace('-', '')
        Write-Host "MAC Address obtained successfully: $($this.MacAddress)"
        return $this.MacAddress
    }

    [bool]EnableTelnet() {
        $url = "http://$($this.HostAddress)/cgi-bin/telnetenable.cgi?telnetenable=1&key=$($this.MacAddress)"
        Write-Host "Telnet Enable URL: $url"

        try {
            $response = Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing
        }
        catch {
            Write-Host "Failed to enable Telnet. Error: $_"
            return $false
        }

        if ($response.Content -match "if \(1 == 1\)" -or $response.Content -match "telnet开启") {
            Write-Host "Telnet has been successfully enabled."
            $this.Method = 0
            if ($response.Content -match "telnet开启") {
                $this.Method = 1
            }
            return $true
        }
        else {
            Write-Host "Failed to enable Telnet."
            return $false
        }
    }

    [System.Tuple[string, string]] GetAdminPassword() {
        $adminUsername = $null
        $adminPassword = $null

        if ($this.Method -eq 0) {
            $username = "root"
            $password = "Fh@$($this.MacAddress.Substring($this.MacAddress.Length - 6))"

            Write-Host "Using Username: $username"
            Write-Host "Using Password: $password"

            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect($this.HostAddress, $this.Port)
                $stream = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $writer = New-Object System.IO.StreamWriter($stream)

                $reader.ReadLine() | Out-Null
                $writer.WriteLine($username)
                $writer.Flush()

                $reader.ReadLine() | Out-Null
                $writer.WriteLine($password)
                $writer.Flush()

                $writer.WriteLine("cat /flash/cfg/agentconf/factory.conf")
                $writer.WriteLine("exit")
                $writer.Flush()

                $result = $reader.ReadToEnd()
            }
            catch {
                Write-Host "Telnet connection failed: $_"
                return $null
            }

            if ($result -match 'TelecomAccount=(.*)') {
                $adminUsername = $matches[1].Trim()
            }
            if ($result -match 'TelecomPasswd=(.*)') {
                $adminPassword = $matches[1].Trim()
            }

            Write-Host "factory.conf: $result"
        }
        elseif ($this.Method -eq 1) {
            $username = "admin"
            $password = "Fh@$($this.MacAddress.Substring($this.MacAddress.Length - 6))"

            Write-Host "Using Username: $username"
            Write-Host "Using Password: $password"

            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect($this.HostAddress, $this.Port)
                $stream = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $writer = New-Object System.IO.StreamWriter($stream)

                $reader.ReadLine() | Out-Null
                $writer.WriteLine($username)
                $writer.Flush()

                $reader.ReadLine() | Out-Null
                $writer.WriteLine($password)
                $writer.Flush()

                Start-Sleep -Milliseconds 500
                $writer.WriteLine("load_cli factory")
                $writer.Flush()
                Start-Sleep -Milliseconds 500
                $writer.WriteLine("show admin_pwd")
                $writer.Flush()
                Start-Sleep -Milliseconds 500
                $writer.WriteLine("show admin_name")
                $writer.Flush()
                Start-Sleep -Milliseconds 500
                $writer.WriteLine("exit")
                $writer.Flush()
                Start-Sleep -Milliseconds 500
                $writer.WriteLine("cfg_cmd get InternetGatewayDevice.DeviceInfo.X_CMCC_TeleComAccount.Username")
                $writer.Flush()
                Start-Sleep -Milliseconds 500
                $writer.WriteLine("cfg_cmd get InternetGatewayDevice.DeviceInfo.X_CMCC_TeleComAccount.Password")
                $writer.Flush()
                Start-Sleep -Milliseconds 500
                $writer.WriteLine("exit")
                $writer.Flush()
                Start-Sleep -Milliseconds 500

                $result = $reader.ReadToEnd()
            }
            catch {
                Write-Host "Telnet connection failed: $_"
                return $null
            }

            if ($result -match 'admin_name=(.*)') {
                $adminUsername = $matches[1].Trim()
            }
            if ($result -match 'admin_pwd=(.*)') {
                $adminPassword = $matches[1].Trim()
            }

            if (-not $adminUsername -or -not $adminPassword) {
                Write-Host "Failed to obtain Admin Username and Password from factory mode."
                if ($result -match "Unknown command") {
                    Write-Host "Entering experimental mode. This mode is based on tutorial methods and has not been fully tested. If you successfully retrieve the results, please provide feedback to the author via an issue report."
                    $obtainResult = Get-ValueFromText -Text $result
                    if ($obtainResult.Count -eq 2) {
                        $adminUsername = $obtainResult[0]
                        $adminPassword = $obtainResult[1]
                    }
                    else {
                        Write-Host "Experimental mode failed."
                        return $null
                    }
                }
                else {
                    return $null
                }
            }

            Write-Host "Telnet Result: $result"
        }

        return [System.Tuple]::Create($adminUsername, $adminPassword)
    }

    [System.Tuple[string, string]] ManageModem() {
        if (-not $this.EnableTelnet()) {
            return $null
        }
        return $this.GetAdminPassword()
    }

    [void] Main() {
        try {
            # 自动获取默认网关
            $this.HostAddress = $this.GetDefaultGateway()
            if (-not $this.HostAddress) {
                Write-Host "Failed to automatically obtain default gateway. Please enter it manually."
                $this.HostAddress = Read-Host -Prompt "Please enter the IP address of the modem (default:192.168.0.1)"
                if (-not $this.HostAddress) {
                    $this.HostAddress = "192.168.0.1"
                }
            }

            if (-not $this.HostAddress) {
                Write-Host "Host address must not be empty."
                exit 0
            }

            if (-not $this.HostAddress -match "^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$") {
                Write-Host "Invalid host address."
                exit 0
            }

            if (-not (Test-Connection -ComputerName $this.HostAddress -Count 1 -Quiet)) {
                Write-Host "Host $this.HostAddress is unreachable."
                exit 0
            }

            $this.MacAddress = $this.GetMacAddress()
            if (-not $this.MacAddress) {
                Write-Host "Failed to obtain MAC address."
                exit 0
            }

            $data = $this.ManageModem()
            if ($data -and $data.Item1 -and $data.Item2) {
                Clear-Console
                Write-Host "Successfully obtained Admin Username and Password for $($this.HostAddress)!"
                Write-Host "Username: $($data.Item1)"
                Write-Host "Password: $($data.Item2)"
            }
            else {
                Write-Host "Failed to obtain Admin Username and Password."
                Write-Host "Please follow the manual confirmation steps at 'https://www.bilibili.com/read/cv21044770/' and modify the code if necessary."
                exit 0
            }
        }
        catch {
            Write-Host "An error occurred: $_"
            exit 0
        }
    }
}

$manager = [ModemManager]::new()
$manager.Main()
