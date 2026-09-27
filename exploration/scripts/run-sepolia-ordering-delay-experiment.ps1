[CmdletBinding()]
param(
    [string]$RpcUrl = $env:SEPOLIA_RPC_URL,
    [string]$PrivateKey = $env:DEPLOYER_PRIVATE_KEY,
    [string]$DeploymentFile = 'deployments/exploration-sepolia.json',
    [int]$BurstCount = 3,
    [int]$DelaySeconds = 60,
    [int]$ReceiptTimeoutSeconds = 180,
    [switch]$SkipSetup,
    [int]$GasLimit = 1000000,
    [string]$OutputFile = 'deployments/exploration-sepolia-ordering-delay-results.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RpcUrl)) { throw 'SEPOLIA_RPC_URL is required.' }
if ([string]::IsNullOrWhiteSpace($PrivateKey)) { throw 'DEPLOYER_PRIVATE_KEY is required.' }
if ($BurstCount -lt 2) { throw 'BurstCount must be at least 2.' }
if ($DelaySeconds -lt 1) { throw 'DelaySeconds must be at least 1.' }
if ($GasLimit -lt 300000) { throw 'GasLimit must be at least 300000.' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$deploymentPath = Join-Path $repoRoot $DeploymentFile
$outputPath = Join-Path $repoRoot $OutputFile
if (-not (Test-Path -LiteralPath $deploymentPath)) { throw "Deployment metadata not found: $deploymentPath" }
$deployment = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
if ([int64]$deployment.chainId -ne 11155111) { throw 'Deployment file is not Sepolia metadata.' }
$pool = [string]$deployment.contracts.LendingPool
$actor = (& cast wallet address --private-key $PrivateKey).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($actor)) { throw 'Unable to derive actor address from private key.' }

function Convert-RpcQuantity([object]$Value) {
    $text = ([string]$Value).Trim()
    if ($text -notmatch '^(?<token>0[xX][0-9a-fA-F]+|\d+)') { throw "Expected an RPC numeric quantity, received '$text'." }
    $token = $Matches['token']
    if ($token -match '^0[xX]') { return [System.Numerics.BigInteger]::Parse("0$($token.Substring(2))", [Globalization.NumberStyles]::AllowHexSpecifier, [Globalization.CultureInfo]::InvariantCulture) }
    return [System.Numerics.BigInteger]::Parse($token, [Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-CastJson([string[]]$Arguments) {
    $raw = & cast @Arguments --json
    if ($LASTEXITCODE -ne 0) { throw "cast failed: $($Arguments -join ' ')" }
    $parsed = ($raw -join "`n") | ConvertFrom-Json
    if ($parsed.PSObject.Properties.Name -contains 'data') {
        if ($parsed.success -ne $true) { throw "cast returned an error: $((@($parsed.errors) | ForEach-Object { $_.message }) -join '; ')" }
        return $parsed.data
    }
    return $parsed
}

function Get-Uint([string]$Address, [string]$Signature, [string]$Argument = $null) {
    $callArgs = @('call', $Address, $Signature)
    if ($null -ne $Argument) { $callArgs += $Argument }
    $callArgs += @('--rpc-url', $RpcUrl)
    $value = (& cast @callArgs).Trim()
    if ($LASTEXITCODE -ne 0) { throw "cast call failed: $Signature" }
    return [string](Convert-RpcQuantity $value)
}

function Get-Snapshot([string]$Label) {
    $latest = Invoke-CastJson @('block', 'latest', '--rpc-url', $RpcUrl)
    return [ordered]@{
        label = $Label; observedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        blockNumber = [string](Convert-RpcQuantity ((& cast block-number --rpc-url $RpcUrl).Trim()))
        blockTimestamp = [string](Convert-RpcQuantity $latest.timestamp)
        lastAccrualTimestamp = Get-Uint $pool 'lastAccrualTimestamp()(uint256)'
        borrowIndex = Get-Uint $pool 'borrowIndex()(uint256)'
        principalDebt = Get-Uint $pool 'principalDebt(address)(uint256)' $actor
        totalDaiBorrowed = Get-Uint $pool 'totalDaiBorrowed()(uint256)'
    }
}

function Invoke-ForgeSetup() {
    $weth = [string]$deployment.contracts.MockWETH
    $dai = [string]$deployment.contracts.MockDAI
    $args = @('script', 'script/ExplorationTimestampSetup.s.sol:ExplorationTimestampSetup', '--sig', 'run(address,address,address)', $pool, $weth, $dai, '--rpc-url', $RpcUrl, '--private-key', $PrivateKey, '--broadcast', '--slow', '--gas-limit', [string]$GasLimit)
    Push-Location $repoRoot
    try { & forge @args; if ($LASTEXITCODE -ne 0) { throw 'Timestamp setup failed.' } }
    finally { Pop-Location }
}

function Send-Async([string]$Action, [System.Numerics.BigInteger]$Nonce) {
    $submitted = Get-Date
    $raw = & cast send $pool 'repay(uint256)' 0 --rpc-url $RpcUrl --private-key $PrivateKey --nonce ([string]$Nonce) --gas-limit $GasLimit --async
    if ($LASTEXITCODE -ne 0) { throw "Failed to submit $Action transaction." }
    $match = [regex]::Match(($raw -join "`n"), '0x[0-9a-fA-F]{64}')
    if (-not $match.Success) { throw "Could not parse transaction hash for $Action from cast output." }
    return [ordered]@{ action = $Action; submissionOrder = 0; txHash = $match.Value; submittedAtUtc = $submitted.ToUniversalTime().ToString('o') }
}

function Complete-Receipt([System.Collections.IDictionary]$Pending) {
    $started = [DateTime]::Parse($Pending.submittedAtUtc).ToUniversalTime()
    $deadline = (Get-Date).ToUniversalTime().AddSeconds($ReceiptTimeoutSeconds)
    do {
        try { $receipt = Invoke-CastJson @('receipt', $Pending.txHash, '--rpc-url', $RpcUrl); if ($null -ne $receipt) { break } }
        catch { if ((Get-Date).ToUniversalTime() -ge $deadline) { throw }; }
        Start-Sleep -Seconds 2
    } while ((Get-Date).ToUniversalTime() -lt $deadline)
    if ($null -eq $receipt) { throw "Timed out waiting for receipt $($Pending.txHash)." }
    $received = (Get-Date).ToUniversalTime()
    $blockNumber = Convert-RpcQuantity $receipt.blockNumber
    $block = Invoke-CastJson @('block', [string]$blockNumber, '--rpc-url', $RpcUrl)
    $gasUsed = Convert-RpcQuantity $receipt.gasUsed
    $gasPrice = Convert-RpcQuantity $receipt.effectiveGasPrice
    $Pending.receiptAtUtc = $received.ToString('o')
    $Pending.receiptLatencySeconds = [math]::Round(($received - $started).TotalSeconds, 3)
    $Pending.blockNumber = [string]$blockNumber
    $Pending.blockTimestamp = [string](Convert-RpcQuantity $block.timestamp)
    $Pending.transactionIndex = [string](Convert-RpcQuantity $receipt.transactionIndex)
    $Pending.receiptStatus = [string]$receipt.status
    $Pending.gasUsed = [string]$gasUsed
    $Pending.effectiveGasPriceWei = [string]$gasPrice
    $Pending.totalFeeWei = [string]($gasUsed * $gasPrice)
    $Pending.explorerUrl = "https://sepolia.etherscan.io/tx/$($Pending.txHash)"
    return $Pending
}

if (-not $SkipSetup) {
    Write-Host 'Creating a borrower position for the ordering experiment...'
    Invoke-ForgeSetup
} else { Write-Host 'Using the existing borrower position; setup transaction will not be sent.' }

$beforeBurst = Get-Snapshot 'before-burst'
if ([System.Numerics.BigInteger]::Parse($beforeBurst.principalDebt) -le 0) { throw 'No borrower debt found. Omit -SkipSetup to create a position.' }

$nonceText = (& cast nonce $actor --rpc-url $RpcUrl --block pending).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the actor pending nonce.' }
$startingNonce = Convert-RpcQuantity $nonceText
$pending = @()
for ($i = 1; $i -le $BurstCount; $i++) {
    $record = Send-Async "burst-$i" ($startingNonce + $i - 1)
    $record.submissionOrder = $i
    $pending += $record
}
$burstReceipts = @()
foreach ($record in $pending) { $burstReceipts += Complete-Receipt $record }
$afterBurst = Get-Snapshot 'after-burst'

$delayedStarted = Get-Date
Write-Host "Waiting $DelaySeconds seconds before the delayed interaction..."
Start-Sleep -Seconds $DelaySeconds
$delayedNonce = $startingNonce + $BurstCount
$delayedPending = Send-Async 'delayed-interaction' $delayedNonce
$delayedPending.submissionOrder = $BurstCount + 1
$delayed = Complete-Receipt $delayedPending
$afterDelayed = Get-Snapshot 'after-delayed-interaction'

$ordered = @($burstReceipts + $delayed | Sort-Object { [int64]$_.blockNumber }, { [int64]$_.transactionIndex })
$result = [ordered]@{
    schemaVersion = 1; network = 'sepolia'; chainId = 11155111
    scenario = 'rapid-transactions-and-delayed-interaction'; deploymentFile = $DeploymentFile
    contracts = [ordered]@{ LendingPool = $pool }; actor = $actor
    parameters = [ordered]@{ burstCount = $BurstCount; delaySeconds = $DelaySeconds; receiptTimeoutSeconds = $ReceiptTimeoutSeconds }
    snapshots = @($beforeBurst, $afterBurst, $afterDelayed)
    transactionsInSubmissionOrder = @($burstReceipts + $delayed)
    transactionsInCanonicalOrder = $ordered
    interpretation = 'Submission order is local observation; canonical ordering comes from receipt blockNumber and transactionIndex. Receipt latency is not settlement or finality, and the delayed wait itself does not mutate contract state.'
}
$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Ordering/delay evidence written to $outputPath"
