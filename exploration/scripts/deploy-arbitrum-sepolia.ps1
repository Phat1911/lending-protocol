[CmdletBinding()]
param(
    [string]$RpcUrl = $env:ARBITRUM_SEPOLIA_RPC_URL,
    [string]$PrivateKey = $env:DEPLOYER_PRIVATE_KEY,
    [int]$GasLimit = 10000000,
    [switch]$SkipBroadcast,
    [switch]$CollectOnly
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RpcUrl)) { throw 'ARBITRUM_SEPOLIA_RPC_URL is required.' }
if (-not $SkipBroadcast -and -not $CollectOnly -and [string]::IsNullOrWhiteSpace($PrivateKey)) { throw 'DEPLOYER_PRIVATE_KEY is required for broadcast mode.' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$broadcastFile = Join-Path $repoRoot 'broadcast\ExplorationDeploy.s.sol\421614\run-latest.json'
$outputFile = Join-Path $repoRoot 'deployments\exploration-arbitrum-sepolia.json'

if (-not $CollectOnly) {
    $args = @('script', 'script/ExplorationDeploy.s.sol:ExplorationDeploy', '--rpc-url', $RpcUrl)
    if ($SkipBroadcast) { $args += '--slow' } else { $args += @('--private-key', $PrivateKey, '--broadcast', '--slow', '--gas-limit', [string]$GasLimit) }
    Push-Location $repoRoot
    try { & forge @args; if ($LASTEXITCODE -ne 0) { throw "forge script failed with exit code $LASTEXITCODE." } }
    finally { Pop-Location }
}
if ($SkipBroadcast -and -not $CollectOnly) { Write-Host 'Dry run completed. No deployment metadata was written.'; exit 0 }
if (-not (Test-Path -LiteralPath $broadcastFile)) { throw "Broadcast file not found: $broadcastFile" }

function Convert-RpcQuantity([object]$Value) {
    $text = ([string]$Value).Trim(); if ($text -notmatch '^(?<token>0[xX][0-9a-fA-F]+|\d+)') { throw "Invalid RPC quantity: $text" }
    $token = $Matches['token']
    if ($token -match '^0[xX]') { return [System.Numerics.BigInteger]::Parse("0$($token.Substring(2))", [Globalization.NumberStyles]::AllowHexSpecifier, [Globalization.CultureInfo]::InvariantCulture) }
    return [System.Numerics.BigInteger]::Parse($token, [Globalization.CultureInfo]::InvariantCulture)
}
function Invoke-CastJson([string[]]$Arguments) {
    $raw = & cast @Arguments --json; if ($LASTEXITCODE -ne 0) { throw "cast failed: $($Arguments -join ' ')" }
    $parsed = ($raw -join "`n") | ConvertFrom-Json
    if ($parsed.PSObject.Properties.Name -contains 'data') { if ($parsed.success -ne $true) { throw 'cast returned an RPC error.' }; return $parsed.data }
    return $parsed
}

$broadcast = Get-Content -LiteralPath $broadcastFile -Raw | ConvertFrom-Json
$creates = @($broadcast.transactions | Where-Object { $_.transactionType -eq 'CREATE' })
if ($creates.Count -ne 4) { throw "Expected 4 CREATE transactions, found $($creates.Count)." }
$expected = @('MockWETH', 'MockDAI', 'MockPriceOracle', 'LendingPool')
$deployer = [string]$creates[0].transaction.from; $contracts = [ordered]@{}; $records = @()
foreach ($tx in $creates) {
    $name = ([string]$tx.contractName).Split('\')[-1]
    if ($name -notin $expected) { throw "Unexpected deployed contract: $name" }
    $receipt = Invoke-CastJson @('receipt', [string]$tx.hash, '--rpc-url', $RpcUrl)
    $blockNumber = Convert-RpcQuantity $receipt.blockNumber; $block = Invoke-CastJson @('block', [string]$blockNumber, '--rpc-url', $RpcUrl)
    $gas = Convert-RpcQuantity $receipt.gasUsed; $price = Convert-RpcQuantity $receipt.effectiveGasPrice
    $contracts[$name] = [string]$tx.contractAddress
    $records += [ordered]@{ schemaVersion=1; network='arbitrum-sepolia'; chainId=421614; scenario='deployment'; contract=$name; txHash=[string]$tx.hash; contractAddress=[string]$tx.contractAddress; deployer=$deployer; blockNumber=[string]$blockNumber; blockTimestamp=[string](Convert-RpcQuantity $block.timestamp); receiptStatus=[string]$receipt.status; gasUsed=[string]$gas; effectiveGasPriceWei=[string]$price; totalFeeWei=[string]($gas*$price); l2FeeComponents=$null; explorerUrl="https://sepolia.arbiscan.io/tx/$($tx.hash)" }
}
function Get-CallAddress([string]$Address, [string]$Signature) {
    $value = (& cast call $Address $Signature --rpc-url $RpcUrl).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { throw "Unable to read $Signature from $Address" }
    return $value
}
$poolAddress = [string]$contracts['LendingPool']
$wethAddress = [string]$contracts['MockWETH']
$daiAddress = [string]$contracts['MockDAI']
$oracleAddress = [string]$contracts['MockPriceOracle']
$poolOwner = Get-CallAddress $poolAddress 'owner()(address)'
$oracleOwner = Get-CallAddress $oracleAddress 'owner()(address)'
$poolCollateral = Get-CallAddress $poolAddress 'collateralToken()(address)'
$poolDai = Get-CallAddress $poolAddress 'daiToken()(address)'
$poolOracle = Get-CallAddress $poolAddress 'oracle()(address)'
if ($poolOwner -ine $deployer -or $oracleOwner -ine $deployer) { throw 'Owner wiring does not match the deployment wallet.' }
if ($poolCollateral -ine $wethAddress -or $poolDai -ine $daiAddress -or $poolOracle -ine $oracleAddress) { throw 'LendingPool token/oracle wiring does not match deployment addresses.' }
$wiring = [ordered]@{ poolOwner=$poolOwner; oracleOwner=$oracleOwner; collateralToken=$poolCollateral; daiToken=$poolDai; oracle=$poolOracle }
$metadata = [ordered]@{ schemaVersion=1; network='arbitrum-sepolia'; chainId=421614; deployedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); deployer=$deployer; contracts=$contracts; wiring=$wiring; transactions=$records }
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputFile -Encoding utf8
Write-Host "Deployment metadata written to $outputFile"
