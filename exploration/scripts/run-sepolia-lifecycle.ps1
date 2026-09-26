[CmdletBinding()]
param(
    [string]$RpcUrl = $env:SEPOLIA_RPC_URL,
    [string]$PrivateKey = $env:DEPLOYER_PRIVATE_KEY,
    [string]$DeploymentFile = 'deployments/exploration-sepolia.json'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RpcUrl)) { throw 'SEPOLIA_RPC_URL is required.' }
if ([string]::IsNullOrWhiteSpace($PrivateKey)) {
    throw 'DEPLOYER_PRIVATE_KEY is required. Use a dedicated testnet wallet.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$deploymentPath = Join-Path $repoRoot $DeploymentFile
if (-not (Test-Path -LiteralPath $deploymentPath)) {
    throw "Deployment metadata not found: $deploymentPath. Run deploy-sepolia.ps1 first."
}

$deployment = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
if ([int64]$deployment.chainId -ne 11155111) { throw 'Deployment file is not Sepolia metadata.' }
$pool = [string]$deployment.contracts.LendingPool
$weth = [string]$deployment.contracts.MockWETH
$dai = [string]$deployment.contracts.MockDAI
if ([string]::IsNullOrWhiteSpace($pool) -or [string]::IsNullOrWhiteSpace($weth) -or [string]::IsNullOrWhiteSpace($dai)) {
    throw 'Deployment metadata is missing LendingPool, MockWETH, or MockDAI.'
}

function Convert-HexToBigInteger([object]$Value) {
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    $token = ($text -split '\s+')[0]
    if ($token -match '^0[xX][0-9a-fA-F]+$') {
        # BigInteger's hex parser treats the high bit as a sign bit. Prefixing
        # a zero keeps normal uint256 RPC quantities positive.
        return [System.Numerics.BigInteger]::Parse("0$($token.Substring(2))", [Globalization.NumberStyles]::AllowHexSpecifier)
    }
    if ($token -match '^\d+$') { return [System.Numerics.BigInteger]::Parse($token) }
    throw "Expected an RPC numeric quantity, received '$text'."
}

function Invoke-CastJson([string[]]$Arguments) {
    $raw = & cast @Arguments --json
    if ($LASTEXITCODE -ne 0) { throw "cast failed: $($Arguments -join ' ')" }
    return ($raw -join "`n") | ConvertFrom-Json
}

function Get-Uint([string]$Address, [string]$Signature, [string]$Argument = $null) {
    $args = @('call', $Address, $Signature)
    if ($null -ne $Argument) { $args += $Argument }
    $args += @('--rpc-url', $RpcUrl)
    $value = (& cast @args).Trim()
    if ($LASTEXITCODE -ne 0) { throw "cast call failed: $Signature" }
    return [string](Convert-HexToBigInteger $value)
}

function Get-Snapshot([string]$Label) {
    $actor = (& cast wallet address --private-key $PrivateKey).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to derive actor address.' }
    $poolDai = Get-Uint $dai 'balanceOf(address)(uint256)' $pool
    $actorDai = Get-Uint $dai 'balanceOf(address)(uint256)' $actor
    $poolWeth = Get-Uint $weth 'balanceOf(address)(uint256)' $pool
    $actorWeth = Get-Uint $weth 'balanceOf(address)(uint256)' $actor
    $supplied = Get-Uint $pool 'totalDaiSupplied()(uint256)'
    $borrowed = Get-Uint $pool 'totalDaiBorrowed()(uint256)'
    $reserves = Get-Uint $pool 'totalReserves()(uint256)'
    $expectedPoolDai = [System.Numerics.BigInteger]::Parse($supplied) - [System.Numerics.BigInteger]::Parse($borrowed) + [System.Numerics.BigInteger]::Parse($reserves)
    $actualPoolDai = [System.Numerics.BigInteger]::Parse($poolDai)

    return [ordered]@{
        label = $Label
        observedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        actor = $actor
        blockNumber = [string](Convert-HexToBigInteger ((& cast block-number --rpc-url $RpcUrl).Trim()))
        blockTimestamp = [string](Convert-HexToBigInteger ((& cast block latest --rpc-url $RpcUrl --json | ConvertFrom-Json).timestamp))
        principalDebt = Get-Uint $pool 'principalDebt(address)(uint256)' $actor
        borrowIndex = Get-Uint $pool 'borrowIndex()(uint256)'
        supplyIndex = Get-Uint $pool 'supplyIndex()(uint256)'
        lastAccrualTimestamp = Get-Uint $pool 'lastAccrualTimestamp()(uint256)'
        suppliedBalance = Get-Uint $pool 'suppliedBalance(address)(uint256)' $actor
        collateralBalance = Get-Uint $pool 'collateralBalance(address)(uint256)' $actor
        totalDaiSupplied = $supplied
        totalDaiBorrowed = $borrowed
        totalReserves = $reserves
        healthFactor = Get-Uint $pool 'healthFactor(address)(uint256)' $actor
        poolDaiBalance = $poolDai
        poolWethBalance = $poolWeth
        actorDaiBalance = $actorDai
        actorWethBalance = $actorWeth
        accountingExpectedPoolDai = [string]$expectedPoolDai
        accountingIdentityHolds = ($actualPoolDai -eq $expectedPoolDai)
    }
}

function Invoke-Lifecycle([string]$Pool, [string]$Weth, [string]$Dai) {
    $args = @(
        'script', 'script/ExplorationLifecycle.s.sol:ExplorationLifecycle',
        '--sig', 'run(address,address,address)', $Pool, $Weth, $Dai,
        '--rpc-url', $RpcUrl, '--private-key', $PrivateKey, '--broadcast', '--slow',
        '--gas-limit', '300000'
    )
    Push-Location $repoRoot
    try {
        & forge @args
        if ($LASTEXITCODE -ne 0) { throw "Lifecycle forge script failed with exit code $LASTEXITCODE." }
    } finally { Pop-Location }
}

$broadcastFile = Join-Path $repoRoot 'broadcast\ExplorationLifecycle.s.sol\11155111\run-latest.json'
$outputFile = Join-Path $repoRoot 'deployments\exploration-sepolia-lifecycle.json'
$before = Get-Snapshot 'before-lifecycle'
Invoke-Lifecycle $pool $weth $dai
if (-not (Test-Path -LiteralPath $broadcastFile)) { throw "Broadcast file not found: $broadcastFile" }
$after = Get-Snapshot 'after-lifecycle'

$broadcast = Get-Content -LiteralPath $broadcastFile -Raw | ConvertFrom-Json
$labels = @('mint-weth', 'mint-dai', 'approve-weth', 'approve-supply-dai', 'supply', 'deposit-collateral', 'borrow', 'approve-repay-dai', 'repay')
$txRecords = @()
$index = 0
foreach ($tx in @($broadcast.transactions)) {
    $hash = [string]$tx.hash
    $receipt = Invoke-CastJson @('receipt', $hash, '--rpc-url', $RpcUrl)
    $blockNumber = Convert-HexToBigInteger $receipt.blockNumber
    $block = Invoke-CastJson @('block', [string]$blockNumber, '--rpc-url', $RpcUrl)
    $gasUsed = Convert-HexToBigInteger $receipt.gasUsed
    $gasPrice = Convert-HexToBigInteger $receipt.effectiveGasPrice
    $fee = if ($null -eq $gasUsed -or $null -eq $gasPrice) { $null } else { $gasUsed * $gasPrice }
    $label = if ($index -lt $labels.Count) { $labels[$index] } else { "transaction-$index" }
    $txRecords += [ordered]@{
        schemaVersion = 1
        network = 'sepolia'
        chainId = 11155111
        scenario = 'baseline-lifecycle'
        run = 1
        action = $label
        txHash = $hash
        blockNumber = [string]$blockNumber
        blockTimestamp = [string](Convert-HexToBigInteger $block.timestamp)
        receiptAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        receiptStatus = [string]$receipt.status
        gasUsed = [string]$gasUsed
        effectiveGasPriceWei = [string]$gasPrice
        totalFeeWei = if ($null -eq $fee) { $null } else { [string]$fee }
        explorerUrl = "https://sepolia.etherscan.io/tx/$hash"
    }
    $index++
}

if (-not $after.accountingIdentityHolds) { throw 'Accounting identity failed after lifecycle.' }
if ([System.Numerics.BigInteger]::Parse($after.principalDebt) -ne 0) { throw 'Repay did not clear principal debt.' }
if ([System.Numerics.BigInteger]::Parse($after.totalDaiBorrowed) -ne 0) { throw 'Repay did not clear total borrowed debt.' }

$result = [ordered]@{
    schemaVersion = 1
    network = 'sepolia'
    chainId = 11155111
    scenario = 'baseline-lifecycle'
    run = 1
    deploymentFile = $DeploymentFile
    contracts = [ordered]@{ LendingPool = $pool; MockWETH = $weth; MockDAI = $dai }
    before = $before
    after = $after
    transactions = $txRecords
    assertions = [ordered]@{
        accountingIdentityHolds = $after.accountingIdentityHolds
        principalDebtCleared = ([System.Numerics.BigInteger]::Parse($after.principalDebt) -eq 0)
        totalBorrowedCleared = ([System.Numerics.BigInteger]::Parse($after.totalDaiBorrowed) -eq 0)
        ownerUnchangedByThisHarness = 'The lifecycle calls no owner/admin setter.'
    }
}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputFile -Encoding utf8
Write-Host "Lifecycle evidence written to $outputFile"
