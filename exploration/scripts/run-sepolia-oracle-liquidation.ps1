[CmdletBinding()]
param(
    [string]$RpcUrl = $env:SEPOLIA_RPC_URL,
    [string]$BorrowerPrivateKey = $env:DEPLOYER_PRIVATE_KEY,
    [string]$OracleOwnerPrivateKey = $env:ORACLE_OWNER_PRIVATE_KEY,
    [string]$LiquidatorPrivateKey = $env:LIQUIDATOR_PRIVATE_KEY,
    [string]$DeploymentFile = 'deployments/exploration-sepolia.json',
    [switch]$SkipSetup,
    [string]$SupplyAmount = '1000000000000000000000',
    [string]$CollateralAmount = '1000000000000000000',
    [string]$BorrowAmount = '500000000000000000000',
    [string]$UnhealthyWethPrice = '500000000000000000000',
    [string]$LiquidatorFunding = '600000000000000000000',
    [int]$GasLimit = 1000000,
    [string]$OutputFile = 'deployments/exploration-sepolia-oracle-liquidation-results.json'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RpcUrl)) { throw 'SEPOLIA_RPC_URL is required.' }
if ([string]::IsNullOrWhiteSpace($BorrowerPrivateKey)) { throw 'DEPLOYER_PRIVATE_KEY is required.' }
if ([string]::IsNullOrWhiteSpace($OracleOwnerPrivateKey)) { $OracleOwnerPrivateKey = $BorrowerPrivateKey }
if ([string]::IsNullOrWhiteSpace($LiquidatorPrivateKey)) { $LiquidatorPrivateKey = $BorrowerPrivateKey }
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
$oracle = [string]$deployment.contracts.MockPriceOracle

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

function Get-Address([string]$Key) {
    $value = (& cast wallet address --private-key $Key).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to derive address from private key.' }
    return $value
}

function Get-Uint([string]$Address, [string]$Signature, [string]$Argument = $null) {
    $args = @('call', $Address, $Signature)
    if ($null -ne $Argument) { $args += $Argument }
    $args += @('--rpc-url', $RpcUrl)
    $value = (& cast @args).Trim()
    if ($LASTEXITCODE -ne 0) { throw "cast call failed: $Signature" }
    return [string](Convert-RpcQuantity $value)
}

function Get-Snapshot([string]$Label, [string]$Borrower, [string]$Liquidator) {
    $latest = Invoke-CastJson @('block', 'latest', '--rpc-url', $RpcUrl)
    return [ordered]@{
        label = $Label; observedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        blockNumber = [string](Convert-RpcQuantity ((& cast block-number --rpc-url $RpcUrl).Trim()))
        blockTimestamp = [string](Convert-RpcQuantity $latest.timestamp)
        wethPrice = Get-Uint $oracle 'getPrice(address)(uint256)' $weth
        daiPrice = Get-Uint $oracle 'getPrice(address)(uint256)' $dai
        healthFactor = Get-Uint $pool 'healthFactor(address)(uint256)' $Borrower
        collateralBalance = Get-Uint $pool 'collateralBalance(address)(uint256)' $Borrower
        principalDebt = Get-Uint $pool 'principalDebt(address)(uint256)' $Borrower
        totalDaiBorrowed = Get-Uint $pool 'totalDaiBorrowed()(uint256)'
        totalReserves = Get-Uint $pool 'totalReserves()(uint256)'
        borrowerDaiBalance = Get-Uint $dai 'balanceOf(address)(uint256)' $Borrower
        liquidatorDaiBalance = Get-Uint $dai 'balanceOf(address)(uint256)' $Liquidator
        liquidatorWethBalance = Get-Uint $weth 'balanceOf(address)(uint256)' $Liquidator
    }
}

function Invoke-Forge([string]$ScriptName, [string]$Key, [string[]]$ScriptArgs) {
    $args = @('script', $ScriptName) + $ScriptArgs + @('--rpc-url', $RpcUrl, '--private-key', $Key, '--broadcast', '--slow', '--gas-limit', [string]$GasLimit)
    Push-Location $repoRoot
    try { & forge @args; if ($LASTEXITCODE -ne 0) { throw "Forge script failed: $ScriptName" } }
    finally { Pop-Location }
}

function Get-ReceiptRecord([string]$BroadcastPath, [string]$Action, [string]$Actor) {
    $broadcast = Get-Content -LiteralPath (Join-Path $repoRoot $BroadcastPath) -Raw | ConvertFrom-Json
    $tx = @($broadcast.transactions)[-1]
    $hash = [string]$tx.hash
    $receipt = Invoke-CastJson @('receipt', $hash, '--rpc-url', $RpcUrl)
    $blockNumber = Convert-RpcQuantity $receipt.blockNumber
    $block = Invoke-CastJson @('block', [string]$blockNumber, '--rpc-url', $RpcUrl)
    $gasUsed = Convert-RpcQuantity $receipt.gasUsed
    $gasPrice = Convert-RpcQuantity $receipt.effectiveGasPrice
    return [ordered]@{
        action = $Action; actor = $Actor; txHash = $hash; blockNumber = [string]$blockNumber
        blockTimestamp = [string](Convert-RpcQuantity $block.timestamp); receiptStatus = [string]$receipt.status
        gasUsed = [string]$gasUsed; effectiveGasPriceWei = [string]$gasPrice
        totalFeeWei = [string]($gasUsed * $gasPrice); explorerUrl = "https://sepolia.etherscan.io/tx/$hash"
    }
}

$borrower = Get-Address $BorrowerPrivateKey
$owner = Get-Address $OracleOwnerPrivateKey
$liquidator = Get-Address $LiquidatorPrivateKey
$records = @()
if (-not $SkipSetup) {
    Invoke-Forge 'script/ExplorationOracleLiquidation.s.sol:ExplorationOracleLiquidationSetup' $BorrowerPrivateKey @('--sig', 'run(address,address,address,uint256,uint256,uint256)', $pool, $weth, $dai, $SupplyAmount, $CollateralAmount, $BorrowAmount)
    $records += Get-ReceiptRecord 'broadcast\ExplorationOracleLiquidation.s.sol\11155111\run-latest.json' 'position-setup' $borrower
} else { Write-Host 'Using the existing borrower position; setup transaction will not be sent.' }

$healthy = Get-Snapshot 'healthy-position' $borrower $liquidator
Invoke-Forge 'script/ExplorationOracleLiquidation.s.sol:ExplorationOraclePriceChange' $OracleOwnerPrivateKey @('--sig', 'run(address,address,uint256)', $oracle, $weth, $UnhealthyWethPrice)
$records += Get-ReceiptRecord 'broadcast\ExplorationOracleLiquidation.s.sol\11155111\run-latest.json' 'oracle-price-change' $owner
$unhealthy = Get-Snapshot 'after-price-change-before-liquidation' $borrower $liquidator
Invoke-Forge 'script/ExplorationOracleLiquidation.s.sol:ExplorationOracleLiquidation' $LiquidatorPrivateKey @('--sig', 'run(address,address,address,uint256)', $pool, $dai, $borrower, $LiquidatorFunding)
$records += Get-ReceiptRecord 'broadcast\ExplorationOracleLiquidation.s.sol\11155111\run-latest.json' 'liquidation' $liquidator
$after = Get-Snapshot 'after-liquidation' $borrower $liquidator

$result = [ordered]@{
    schemaVersion = 1; network = 'sepolia'; chainId = 11155111; scenario = 'oracle-price-and-liquidation'
    deploymentFile = $DeploymentFile; contracts = [ordered]@{ LendingPool = $pool; MockWETH = $weth; MockDAI = $dai; MockPriceOracle = $oracle }
    roles = [ordered]@{ borrower = $borrower; oracleOwner = $owner; liquidator = $liquidator }
    assumptions = @('MockPriceOracle is owner-controlled; this is a trust assumption, not a production oracle-manipulation finding.', 'Mock tokens are unrestricted testnet mints and do not represent real asset value.')
    snapshots = @($healthy, $unhealthy, $after); transactions = $records
    interpretation = 'The experiment tests the existing current-price health-factor and liquidation rules. A healthy position must not be liquidated; after the recorded price change, liquidation is attempted only when the observed health factor is below 1e18.'
}
$result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Oracle/liquidation evidence written to $outputPath"
