[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$required = @(
    'SEPOLIA_RPC_URL',
    'ARBITRUM_SEPOLIA_RPC_URL',
    'BASE_SEPOLIA_RPC_URL'
)

$missing = @($required | Where-Object {
    $value = [Environment]::GetEnvironmentVariable($_)
    [string]::IsNullOrWhiteSpace($value)
})

if ($missing.Count -gt 0) {
    throw "Missing required RPC environment variable(s): $($missing -join ', ')"
}

$sample = [ordered]@{
    schemaVersion = 1
    network = 'example'
    chainId = 0
    scenario = 'configuration-check'
    run = 0
    txHash = $null
    blockNumber = $null
    blockTimestamp = $null
    submittedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    receiptAtUtc = $null
    receiptStatus = $null
    gasUsed = $null
    effectiveGasPriceWei = $null
    totalFeeWei = $null
    l2FeeComponents = $null
    explorerUrl = $null
    notes = 'Configuration validated; no transaction was broadcast.'
}

$sample | ConvertTo-Json -Depth 5
