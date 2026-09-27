[CmdletBinding()]
param(
    [string]$RpcUrl = $env:SEPOLIA_RPC_URL,
    [string]$PrivateKey = $env:DEPLOYER_PRIVATE_KEY,
    [string]$DeploymentFile = 'deployments/exploration-sepolia.json',
    [int]$Runs = 3,
    [int]$WaitSeconds = 60,
    [int]$GasLimit = 1000000,
    [switch]$SkipSetup,
    [string]$OutputFile = 'deployments/exploration-sepolia-timestamp-results.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RpcUrl)) { throw 'SEPOLIA_RPC_URL is required.' }
if ([string]::IsNullOrWhiteSpace($PrivateKey)) { throw 'DEPLOYER_PRIVATE_KEY is required.' }
if ($Runs -lt 1) { throw 'Runs must be at least 1.' }
if ($WaitSeconds -lt 1) { throw 'WaitSeconds must be at least 1.' }
if ($GasLimit -lt 300000) { throw 'GasLimit must be at least 300000.' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$deploymentPath = Join-Path $repoRoot $DeploymentFile
$outputPath = Join-Path $repoRoot $OutputFile
if (-not (Test-Path -LiteralPath $deploymentPath)) { throw "Deployment metadata not found: $deploymentPath" }

$deployment = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
if ([int64]$deployment.chainId -ne 11155111) { throw 'Deployment file is not Sepolia metadata.' }
$pool = [string]$deployment.contracts.LendingPool
$weth = [string]$deployment.contracts.MockWETH
$dai = [string]$deployment.contracts.MockDAI

function Convert-HexToBigInteger([object]$Value) {
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    # cast may append a human-readable annotation, for example:
    # `0x01 [1]` or `1000000000000000000 [1e18]`. Keep only the RPC quantity.
    if ($text -notmatch '^(?<token>0[xX][0-9a-fA-F]+|\d+)') {
        throw "Expected an RPC numeric quantity, received '$text'."
    }
    $token = $Matches['token']
    if ($token -match '^0[xX][0-9a-fA-F]+$') {
        $digits = $token.Substring(2)
        return [System.Numerics.BigInteger]::Parse(
            "0$digits",
            [Globalization.NumberStyles]::AllowHexSpecifier,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    return [System.Numerics.BigInteger]::Parse($token, [Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-CastJson([string[]]$Arguments) {
    $raw = & cast @Arguments --json
    if ($LASTEXITCODE -ne 0) { throw "cast failed: $($Arguments -join ' ')" }
    $parsed = ($raw -join "`n") | ConvertFrom-Json
    # Newer cast releases wrap JSON responses as { success, data, errors };
    # older releases returned the RPC object directly. Support both formats.
    if ($parsed.PSObject.Properties.Name -contains 'data') {
        if ($parsed.success -ne $true) {
            $message = (($parsed.errors | ForEach-Object { $_.message }) -join '; ')
            throw "cast returned an error: $message"
        }
        return $parsed.data
    }
    return $parsed
}

function Get-Uint([string]$Address, [string]$Signature, [string]$Argument = $null) {
    $args = @('call', $Address, $Signature)
    if ($null -ne $Argument) { $args += $Argument }
    $args += @('--rpc-url', $RpcUrl)
    $value = (& cast @args).Trim()
    if ($LASTEXITCODE -ne 0) { throw "cast call failed: $Signature" }
    return [string](Convert-HexToBigInteger $value)
}

function Get-Actor() {
    $actor = (& cast wallet address --private-key $PrivateKey).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to derive actor address.' }
    return $actor
}

function Get-Snapshot([string]$Actor, [string]$Label) {
    $latest = Invoke-CastJson @('block', 'latest', '--rpc-url', $RpcUrl)
    return [ordered]@{
        label = $Label
        observedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        actor = $Actor
        blockNumber = [string](Convert-HexToBigInteger ((& cast block-number --rpc-url $RpcUrl).Trim()))
        blockTimestamp = [string](Convert-HexToBigInteger $latest.timestamp)
        lastAccrualTimestamp = Get-Uint $pool 'lastAccrualTimestamp()(uint256)'
        borrowIndex = Get-Uint $pool 'borrowIndex()(uint256)'
        supplyIndex = Get-Uint $pool 'supplyIndex()(uint256)'
        principalDebt = Get-Uint $pool 'principalDebt(address)(uint256)' $Actor
        totalDaiBorrowed = Get-Uint $pool 'totalDaiBorrowed()(uint256)'
        totalReserves = Get-Uint $pool 'totalReserves()(uint256)'
    }
}

function Invoke-ForgeScript([string]$ScriptName, [string[]]$ScriptArgs) {
    $args = @('script', $ScriptName) + $ScriptArgs + @('--rpc-url', $RpcUrl, '--private-key', $PrivateKey, '--broadcast', '--slow', '--gas-limit', [string]$GasLimit)
    Push-Location $repoRoot
    try {
        & forge @args
        if ($LASTEXITCODE -ne 0) { throw "Forge script failed: $ScriptName" }
    } finally { Pop-Location }
}

function Get-Records([string]$BroadcastPath, [string]$Scenario, [int]$Run, [string[]]$Labels) {
    $broadcast = Get-Content -LiteralPath (Join-Path $repoRoot $BroadcastPath) -Raw | ConvertFrom-Json
    $records = @()
    $index = 0
    foreach ($tx in @($broadcast.transactions)) {
        $hash = [string]$tx.hash
        $receipt = Invoke-CastJson @('receipt', $hash, '--rpc-url', $RpcUrl)
        $blockNumber = Convert-HexToBigInteger $receipt.blockNumber
        $block = Invoke-CastJson @('block', [string]$blockNumber, '--rpc-url', $RpcUrl)
        $gasUsed = Convert-HexToBigInteger $receipt.gasUsed
        $gasPrice = Convert-HexToBigInteger $receipt.effectiveGasPrice
        $label = if ($index -lt $Labels.Count) { $Labels[$index] } else { "transaction-$index" }
        $records += [ordered]@{
            schemaVersion = 1; network = 'sepolia'; chainId = 11155111
            scenario = $Scenario; run = $Run; action = $label; txHash = $hash
            blockNumber = [string]$blockNumber
            blockTimestamp = [string](Convert-HexToBigInteger $block.timestamp)
            receiptAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            receiptStatus = [string]$receipt.status
            gasUsed = [string]$gasUsed
            effectiveGasPriceWei = [string]$gasPrice
            totalFeeWei = [string]($gasUsed * $gasPrice)
            explorerUrl = "https://sepolia.etherscan.io/tx/$hash"
        }
        $index++
    }
    return $records
}

$actor = Get-Actor
$allRuns = @()
for ($run = 1; $run -le $Runs; $run++) {
    Write-Host "Starting timestamp accrual run $run of $Runs..."
    if (-not $SkipSetup) {
        Invoke-ForgeScript 'script/ExplorationTimestampSetup.s.sol:ExplorationTimestampSetup' @('--sig', 'run(address,address,address)', $pool, $weth, $dai)
    } else {
        Write-Host 'Using the existing borrower position; setup transactions will not be sent.'
    }
    $before = Get-Snapshot $actor "run-$run-before-wait"
    if ([System.Numerics.BigInteger]::Parse($before.principalDebt) -le 0) {
        throw 'No existing borrower debt found. Omit -SkipSetup to create a position first.'
    }

    $waitStarted = Get-Date
    Write-Host "Waiting $WaitSeconds seconds of wall-clock time..."
    Start-Sleep -Seconds $WaitSeconds
    $waitEnded = Get-Date

    Invoke-ForgeScript 'script/ExplorationTimestampTrigger.s.sol:ExplorationTimestampTrigger' @('--sig', 'run(address)', $pool)
    $after = Get-Snapshot $actor "run-$run-after-accrual"

    $wallDelta = [math]::Round(($waitEnded - $waitStarted).TotalSeconds, 3)
    $chainDelta = [System.Numerics.BigInteger]::Parse($after.blockTimestamp) - [System.Numerics.BigInteger]::Parse($before.blockTimestamp)
    $indexDelta = [System.Numerics.BigInteger]::Parse($after.borrowIndex) - [System.Numerics.BigInteger]::Parse($before.borrowIndex)
    $debtDelta = [System.Numerics.BigInteger]::Parse($after.principalDebt) - [System.Numerics.BigInteger]::Parse($before.principalDebt)

    $setupRecords = if ($SkipSetup) {
        @()
    } else {
        @(Get-Records 'broadcast\ExplorationTimestampSetup.s.sol\11155111\run-latest.json' 'timestamp-position-setup' $run @('mint-weth','mint-dai','approve-weth','approve-dai','supply','deposit-collateral','borrow'))
    }
    $allRuns += [ordered]@{
        run = $run
        waitStartedUtc = $waitStarted.ToUniversalTime().ToString('o')
        waitEndedUtc = $waitEnded.ToUniversalTime().ToString('o')
        wallClockWaitSeconds = $wallDelta
        onChainTimestampDeltaSeconds = [string]$chainDelta
        borrowIndexDelta = [string]$indexDelta
        principalDebtDelta = [string]$debtDelta
        before = $before
        after = $after
        setupTransactions = $setupRecords
        triggerTransactions = @(Get-Records 'broadcast\ExplorationTimestampTrigger.s.sol\11155111\run-latest.json' 'timestamp-accrual-trigger' $run @('repay-zero'))
    }
}

$result = [ordered]@{
    schemaVersion = 1
    network = 'sepolia'
    chainId = 11155111
    scenario = 'real-time-timestamp-interest-accrual'
    deploymentFile = $DeploymentFile
    contracts = [ordered]@{ LendingPool = $pool; MockWETH = $weth; MockDAI = $dai }
    actor = $actor
    runs = $allRuns
    interpretation = 'Wall-clock waiting does not mutate state. The next state-changing call applies accrual using the elapsed block.timestamp interval.'
}
$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Timestamp experiment evidence written to $outputPath"
