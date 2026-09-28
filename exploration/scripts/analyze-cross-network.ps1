[CmdletBinding()]
param(
    [string]$EvidenceDirectory,
    [string]$OutputJson,
    [string]$OutputMarkdown
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $EvidenceDirectory = Join-Path $PSScriptRoot '..\..\deployments' }
if ([string]::IsNullOrWhiteSpace($OutputJson)) { $OutputJson = Join-Path $PSScriptRoot '..\..\deployments\exploration-cross-network-analysis.json' }
if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) { $OutputMarkdown = Join-Path $PSScriptRoot '..\..\deployments\exploration-cross-network-analysis.md' }

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.psobject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Convert-ToDecimalOrNull {
    param([object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [decimal]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Format-Decimal {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    return ([decimal]$Value).ToString('0.############################', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Median {
    param([decimal[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $ordered = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($ordered.Count / 2)
    if (($ordered.Count % 2) -eq 1) { return $ordered[$middle] }
    return (($ordered[$middle - 1] + $ordered[$middle]) / 2)
}

function Add-Record {
    param(
        [System.Collections.Generic.List[object]]$Records,
        [object]$Transaction,
        [string]$Network,
        [int]$ChainId,
        [string]$Scenario,
        [int]$Run,
        [string]$SourceFile,
        [string]$Action
    )

    $hash = [string](Get-PropertyValue $Transaction 'txHash')
    if ([string]::IsNullOrWhiteSpace($hash)) { return }

    $gas = Convert-ToDecimalOrNull (Get-PropertyValue $Transaction 'gasUsed')
    $price = Convert-ToDecimalOrNull (Get-PropertyValue $Transaction 'effectiveGasPriceWei')
    $fee = Convert-ToDecimalOrNull (Get-PropertyValue $Transaction 'totalFeeWei')
    if ($null -eq $fee -and $null -ne $gas -and $null -ne $price) { $fee = $gas * $price }

    $latency = Convert-ToDecimalOrNull (Get-PropertyValue $Transaction 'receiptLatencySeconds')
    $submitted = Get-PropertyValue $Transaction 'submittedAtUtc'
    $receipt = Get-PropertyValue $Transaction 'receiptAtUtc'
    if ($null -eq $latency -and $null -ne $submitted -and $null -ne $receipt) {
        try {
            $latency = ([DateTimeOffset]::Parse([string]$receipt) - [DateTimeOffset]::Parse([string]$submitted)).TotalSeconds
        } catch { $latency = $null }
    }

    $Records.Add([pscustomobject]@{
        network = $Network
        chainId = $ChainId
        scenario = $Scenario
        run = $Run
        action = $Action
        txHash = $hash
        blockNumber = [string](Get-PropertyValue $Transaction 'blockNumber')
        blockTimestamp = [string](Get-PropertyValue $Transaction 'blockTimestamp')
        receiptStatus = [string](Get-PropertyValue $Transaction 'receiptStatus')
        gasUsed = Format-Decimal $gas
        effectiveGasPriceWei = Format-Decimal $price
        totalFeeWei = Format-Decimal $fee
        receiptLatencySeconds = if ($null -eq $latency) { $null } else { [Math]::Round([double]$latency, 3) }
        l2FeeComponents = Get-PropertyValue $Transaction 'l2FeeComponents'
        explorerUrl = [string](Get-PropertyValue $Transaction 'explorerUrl')
        sourceFile = $SourceFile
    })
}

$records = [System.Collections.Generic.List[object]]::new()
$sourceFiles = [System.Collections.Generic.List[string]]::new()

function Import-JsonFile {
    param([string]$Name)
    $path = Join-Path $EvidenceDirectory $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $sourceFiles.Add($Name)
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

# Deployment metadata is tracked, while the lifecycle/experiment result files
# are intentionally local and ignored. Missing files remain visible below.
$deploymentNames = @(
    'exploration-sepolia.json',
    'exploration-arbitrum-sepolia.json',
    'exploration-base-sepolia.json'
)
foreach ($name in $deploymentNames) {
    $deployment = Import-JsonFile $name
    if ($null -eq $deployment) { continue }
    foreach ($tx in @($deployment.transactions)) {
        Add-Record $records $tx ([string]$deployment.network) ([int]$deployment.chainId) 'deployment' 1 $name ([string](Get-PropertyValue $tx 'contract'))
    }
}

# The first Sepolia baseline runner stopped at a failed repay before it had a
# machine-readable JSON result. Preserve that known failed observation instead
# of silently dropping it from the analysis dataset.
$failedSepoliaRepay = [pscustomobject]@{
    txHash = '0x4beb8c67c981b663468468ecd03d4cb82fe2141ac80f42a28aa8f29710029a7c'
    receiptStatus = '0x0'
    gasUsed = '85633'
    explorerUrl = 'https://sepolia.etherscan.io/tx/0x4beb8c67c981b663468468ecd03d4cb82fe2141ac80f42a28aa8f29710029a7c'
}
Add-Record $records $failedSepoliaRepay 'sepolia' 11155111 'baseline-lifecycle' 1 'exploration-sepolia-lifecycle-results.md' 'initial-repay-attempt'

$lifecycleNames = @(
    'exploration-arbitrum-sepolia-lifecycle-results.json',
    'exploration-base-sepolia-lifecycle-results.json'
)
foreach ($name in $lifecycleNames) {
    $result = Import-JsonFile $name
    if ($null -eq $result) { continue }
    foreach ($run in @($result.runs)) {
        foreach ($tx in @($run.transactions)) {
            Add-Record $records $tx ([string]$result.network) ([int]$result.chainId) ([string]$result.scenario) ([int]$run.run) $name ([string](Get-PropertyValue $tx 'action'))
        }
    }
}

$timestamp = Import-JsonFile 'exploration-sepolia-timestamp-results.json'
if ($null -ne $timestamp) {
    foreach ($run in @($timestamp.runs)) {
        foreach ($tx in @($run.setupTransactions) + @($run.triggerTransactions)) {
            Add-Record $records $tx ([string]$timestamp.network) ([int]$timestamp.chainId) ([string]$timestamp.scenario) ([int]$run.run) 'exploration-sepolia-timestamp-results.json' ([string](Get-PropertyValue $tx 'action'))
        }
    }
}

foreach ($name in @('exploration-sepolia-oracle-liquidation-results.json','exploration-sepolia-ordering-delay-results.json')) {
    $result = Import-JsonFile $name
    if ($null -eq $result) { continue }
    $scenario = [string]$result.scenario
    $transactions = if ($scenario -eq 'rapid-transactions-and-delayed-interaction') { @($result.transactionsInSubmissionOrder) } else { @($result.transactions) }
    foreach ($tx in $transactions) {
        Add-Record $records $tx ([string]$result.network) ([int]$result.chainId) $scenario 1 $name ([string](Get-PropertyValue $tx 'action'))
    }
}

$groups = @($records | Group-Object network, scenario, run | ForEach-Object {
    $items = @($_.Group)
    $gas = @($items | ForEach-Object { Convert-ToDecimalOrNull $_.gasUsed } | Where-Object { $null -ne $_ })
    $prices = @($items | ForEach-Object { Convert-ToDecimalOrNull $_.effectiveGasPriceWei } | Where-Object { $null -ne $_ })
    $fees = @($items | ForEach-Object { Convert-ToDecimalOrNull $_.totalFeeWei } | Where-Object { $null -ne $_ })
    $latencies = @($items | ForEach-Object { Convert-ToDecimalOrNull $_.receiptLatencySeconds } | Where-Object { $null -ne $_ })
    $blocks = @($items | ForEach-Object { Convert-ToDecimalOrNull $_.blockNumber } | Where-Object { $null -ne $_ })
    $timestamps = @($items | ForEach-Object { Convert-ToDecimalOrNull $_.blockTimestamp } | Where-Object { $null -ne $_ })
    $l2Present = @($items | Where-Object { $null -ne $_.l2FeeComponents }).Count
    [pscustomobject]@{
        network = [string]$items[0].network
        chainId = [int]$items[0].chainId
        scenario = [string]$items[0].scenario
        run = [int]$items[0].run
        transactionCount = $items.Count
        successfulCount = @($items | Where-Object { $_.receiptStatus -eq '0x1' -or $_.receiptStatus -eq '1' }).Count
        failedOrUnknownCount = @($items | Where-Object { $_.receiptStatus -ne '0x1' -and $_.receiptStatus -ne '1' }).Count
        gasUsedTotal = if ($gas.Count -eq 0) { $null } else { Format-Decimal (($gas | Measure-Object -Sum).Sum) }
        gasUsedMin = if ($gas.Count -eq 0) { $null } else { Format-Decimal (($gas | Measure-Object -Minimum).Minimum) }
        gasUsedMax = if ($gas.Count -eq 0) { $null } else { Format-Decimal (($gas | Measure-Object -Maximum).Maximum) }
        effectiveGasPriceWeiMedian = if ($prices.Count -eq 0) { $null } else { Format-Decimal (Get-Median $prices) }
        totalFeeWei = if ($fees.Count -eq 0) { $null } else { Format-Decimal (($fees | Measure-Object -Sum).Sum) }
        receiptLatencyCount = $latencies.Count
        receiptLatencyMedianSeconds = if ($latencies.Count -eq 0) { $null } else { [double](Get-Median $latencies) }
        receiptLatencyMinSeconds = if ($latencies.Count -eq 0) { $null } else { [double](($latencies | Measure-Object -Minimum).Minimum) }
        receiptLatencyMaxSeconds = if ($latencies.Count -eq 0) { $null } else { [double](($latencies | Measure-Object -Maximum).Maximum) }
        blockRange = if ($blocks.Count -eq 0) { $null } else { "$(($blocks | Measure-Object -Minimum).Minimum)-$(($blocks | Measure-Object -Maximum).Maximum)" }
        timestampRange = if ($timestamps.Count -eq 0) { $null } else { "$(($timestamps | Measure-Object -Minimum).Minimum)-$(($timestamps | Measure-Object -Maximum).Maximum)" }
        l2FeeComponentRecords = $l2Present
        l2FeeComponentStatus = if ($l2Present -eq $items.Count) { 'present' } elseif ($l2Present -eq 0) { 'missing' } else { 'partial' }
        transactionHashes = @($items | ForEach-Object { $_.txHash })
        sourceFiles = @($items | Select-Object -ExpandProperty sourceFile -Unique)
    }
}) | Sort-Object network, scenario, run

$networkProgression = @($records | Group-Object network | ForEach-Object {
    $items = @($_.Group)
    $blocks = @($items | ForEach-Object { Convert-ToDecimalOrNull $_.blockNumber } | Where-Object { $null -ne $_ })
    $timestamps = @($items | ForEach-Object { Convert-ToDecimalOrNull $_.blockTimestamp } | Where-Object { $null -ne $_ })
    [pscustomobject]@{
        network = [string]$items[0].network
        chainId = [int]$items[0].chainId
        observedTransactionCount = $items.Count
        observedBlockRange = if ($blocks.Count -eq 0) { $null } else { "$(($blocks | Measure-Object -Minimum).Minimum)-$(($blocks | Measure-Object -Maximum).Maximum)" }
        observedTimestampRange = if ($timestamps.Count -eq 0) { $null } else { "$(($timestamps | Measure-Object -Minimum).Minimum)-$(($timestamps | Measure-Object -Maximum).Maximum)" }
        note = 'Block numbers and timestamps are reported within this network only; no cadence equivalence is inferred across networks.'
    }
}) | Sort-Object chainId

$expectedEvidence = @(
    'exploration-sepolia-timestamp-results.json',
    'exploration-sepolia-oracle-liquidation-results.json',
    'exploration-sepolia-ordering-delay-results.json',
    'exploration-arbitrum-sepolia-lifecycle-results.json',
    'exploration-base-sepolia-lifecycle-results.json'
)
$missingEvidence = @($expectedEvidence | Where-Object { $_ -notin $sourceFiles })

$analysis = [pscustomobject]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    methodology = @(
        'Each summary row is derived from the transaction hash records listed in transactionHashes.',
        'totalFeeWei is taken from the receipt record; when absent, it is derived as gasUsed multiplied by effectiveGasPriceWei.',
        'Receipt latency is summarized only for records with submission and receipt timestamps or an explicit receiptLatencySeconds field.',
        'gasUsed, effectiveGasPriceWei, totalFeeWei, and provider-specific L2 fee components are separate fields.',
        'A successful receipt is not treated as settlement or finality.'
    )
    records = @($records)
    summaryByNetworkScenarioRun = @($groups)
    networkProgression = @($networkProgression)
    missingExpectedEvidence = $missingEvidence
    limitations = @(
        'The Sepolia baseline lifecycle is preserved as Markdown rather than a machine-readable JSON result; the known failed initial repay is included, but the other baseline transactions are not re-parsed into this report.',
        'The current Arbitrum and Base lifecycle recorders expose no provider-specific L2 fee decomposition; this remains visible as l2FeeComponentStatus=missing.',
        'These are public testnet observations from particular RPC/provider conditions, not universal performance guarantees.',
        'No network-specific settlement/finality source was recorded by these scripts; receipt latency is therefore the measured timing comparison.'
    )
}

$outputJsonPath = [IO.Path]::GetFullPath($OutputJson)
$outputMarkdownPath = [IO.Path]::GetFullPath($OutputMarkdown)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputJsonPath), (Split-Path -Parent $outputMarkdownPath) | Out-Null
$analysis | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputJsonPath -Encoding utf8

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# Cross-network fee, timing, and block-behavior analysis')
$md.Add('')
$md.Add(('Generated: {0}' -f $analysis.generatedAtUtc))
$md.Add('')
$md.Add('This report is generated from the local raw evidence files. Every summary row links back to transaction hashes in the JSON report. It compares receipt observations only; it does not claim settlement or finality.')
$md.Add('')
$md.Add('## Summary rows')
$md.Add('')
$md.Add('| Network | Chain ID | Scenario | Run | Tx count | Gas total | Total fee (wei) | Receipt latency median/range (s) | Block range | L2 fee components |')
$md.Add('|---|---:|---|---:|---:|---:|---:|---|---|---|')
foreach ($row in $groups) {
    $latency = if ($null -eq $row.receiptLatencyMedianSeconds) { 'not recorded' } else { '{0} / {1}-{2}' -f $row.receiptLatencyMedianSeconds, $row.receiptLatencyMinSeconds, $row.receiptLatencyMaxSeconds }
    $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |' -f $row.network, $row.chainId, $row.scenario, $row.run, $row.transactionCount, $row.gasUsedTotal, $row.totalFeeWei, $latency, $row.blockRange, $row.l2FeeComponentStatus))
}
$md.Add('')
$md.Add('## Network progression')
$md.Add('')
$md.Add('| Network | Chain ID | Observed transaction count | Observed block range | Observed timestamp range |')
$md.Add('|---|---:|---:|---|---|')
foreach ($row in $networkProgression) { $md.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $row.network, $row.chainId, $row.observedTransactionCount, $row.observedBlockRange, $row.observedTimestampRange)) }
$md.Add('')
$md.Add('Block numbers are compared only within each network. An Arbitrum or Base block number is not treated as an L1-equivalent height or as evidence of a shared cadence.')
$md.Add('')
$md.Add('## Limitations')
$md.Add('')
foreach ($limitation in $analysis.limitations) { $md.Add(('- {0}' -f $limitation)) }
$md.Add('')
$md.Add('## Reproduction')
$md.Add('')
$md.Add('```powershell')
$md.Add('powershell -ExecutionPolicy Bypass -File exploration/scripts/analyze-cross-network.ps1')
$md.Add('```')
$md.Add('')
$md.Add('The detailed transaction records, hashes, explorer URLs, and source files are in exploration-cross-network-analysis.json.')
$markdownText = $md -join [Environment]::NewLine
Set-Content -LiteralPath $outputMarkdownPath -Value $markdownText -Encoding utf8

Write-Output ('Cross-network analysis written to {0}' -f $outputJsonPath)
Write-Output ('Markdown summary written to {0}' -f $outputMarkdownPath)
Write-Output ('Records: {0}; summary rows: {1}; missing expected evidence: {2}' -f $records.Count, $groups.Count, $missingEvidence.Count)
