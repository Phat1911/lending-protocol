[CmdletBinding()]
param(
    [string]$RpcUrl = $env:SEPOLIA_RPC_URL,
    [string]$PrivateKey = $env:DEPLOYER_PRIVATE_KEY,
    [switch]$SkipBroadcast,
    [switch]$CollectOnly
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RpcUrl)) {
    throw 'SEPOLIA_RPC_URL is required.'
}

if (-not $SkipBroadcast -and -not $CollectOnly -and [string]::IsNullOrWhiteSpace($PrivateKey)) {
    throw 'DEPLOYER_PRIVATE_KEY is required for broadcast mode. Use a dedicated testnet wallet.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$broadcastDir = Join-Path $repoRoot 'broadcast\ExplorationDeploy.s.sol\11155111'
$broadcastFile = Join-Path $broadcastDir 'run-latest.json'
$outputFile = Join-Path $repoRoot 'deployments\exploration-sepolia.json'

if (-not $CollectOnly) {
    $forgeArgs = @(
        'script',
        'script/ExplorationDeploy.s.sol:ExplorationDeploy',
        '--rpc-url', $RpcUrl
    )

    if ($SkipBroadcast) {
        $forgeArgs += @('--slow')
    } else {
        $forgeArgs += @('--private-key', $PrivateKey, '--broadcast', '--slow')
    }

    Push-Location $repoRoot
    try {
        & forge @forgeArgs
        if ($LASTEXITCODE -ne 0) {
            throw "forge script failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

if ($SkipBroadcast -and -not $CollectOnly) {
    Write-Host 'Dry run completed. No deployment metadata was written.'
    exit 0
}

if (-not (Test-Path -LiteralPath $broadcastFile)) {
    throw "Broadcast file not found: $broadcastFile"
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
    if ($LASTEXITCODE -ne 0) {
        throw "cast failed: $($Arguments -join ' ')"
    }
    return ($raw -join "`n") | ConvertFrom-Json
}

$broadcast = Get-Content -LiteralPath $broadcastFile -Raw | ConvertFrom-Json
$creates = @($broadcast.transactions | Where-Object { $_.transactionType -eq 'CREATE' })
$expected = @('MockWETH', 'MockDAI', 'MockPriceOracle', 'LendingPool')

if ($creates.Count -ne 4) {
    throw "Expected 4 CREATE transactions, found $($creates.Count)."
}

$deployer = [string]$creates[0].transaction.from
$records = @()
$contracts = [ordered]@{}

foreach ($tx in $creates) {
    $shortName = ([string]$tx.contractName).Split('\')[-1]
    if ($shortName -notin $expected) {
        throw "Unexpected deployed contract in broadcast file: $shortName"
    }

    $receipt = Invoke-CastJson @('receipt', [string]$tx.hash, '--rpc-url', $RpcUrl)
    $blockNumber = Convert-HexToBigInteger $receipt.blockNumber
    $block = Invoke-CastJson @('block', [string]$blockNumber, '--rpc-url', $RpcUrl)
    $gasUsed = Convert-HexToBigInteger $receipt.gasUsed
    $effectiveGasPrice = Convert-HexToBigInteger $receipt.effectiveGasPrice
    $totalFee = $null
    if ($null -ne $gasUsed -and $null -ne $effectiveGasPrice) {
        $totalFee = $gasUsed * $effectiveGasPrice
    }

    $contracts[$shortName] = [string]$tx.contractAddress
    $records += [ordered]@{
        schemaVersion = 1
        network = 'sepolia'
        chainId = 11155111
        scenario = 'deployment'
        run = 1
        contract = $shortName
        txHash = [string]$tx.hash
        contractAddress = [string]$tx.contractAddress
        deployer = $deployer
        blockNumber = [string]$blockNumber
        blockTimestamp = [string](Convert-HexToBigInteger $block.timestamp)
        submittedAtUtc = $null
        receiptAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        receiptStatus = [string]$receipt.status
        gasUsed = if ($null -eq $gasUsed) { $null } else { [string]$gasUsed }
        effectiveGasPriceWei = if ($null -eq $effectiveGasPrice) { $null } else { [string]$effectiveGasPrice }
        totalFeeWei = if ($null -eq $totalFee) { $null } else { [string]$totalFee }
        l2FeeComponents = $null
        explorerUrl = "https://sepolia.etherscan.io/tx/$($tx.hash)"
        notes = 'Fresh deployment from ExplorationDeploy.s.sol.'
    }
}

$metadata = [ordered]@{
    schemaVersion = 1
    network = 'sepolia'
    chainId = 11155111
    deployedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    deployer = $deployer
    contracts = $contracts
    transactions = $records
}

$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputFile -Encoding utf8
Write-Host "Deployment metadata written to $outputFile"
