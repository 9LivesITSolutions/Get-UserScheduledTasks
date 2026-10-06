<#
.SYNOPSIS
    Inventaire des tâches planifiées "usermade" sur les serveurs du domaine.

.DESCRIPTION
    Interroge les serveurs AD (ou une liste fournie) via WinRM et liste les tâches
    planifiées hors \Microsoft\* (tâches créées par des admins/applications).
    Exporte en CSV + HTML, et signale les serveurs injoignables.

.PARAMETER ComputerName
    Liste de serveurs. Par défaut : tous les serveurs Windows activés de l'AD.

.PARAMETER SearchBase
    OU de recherche AD (optionnel).

.PARAMETER IncludeVendor
    Inclut aussi les tâches d'éditeurs tiers (Veeam, SentinelOne, Google...).
    Par défaut elles restent listées mais marquées Category = Vendor ; avec
    -ExcludeVendor elles sont masquées.

.PARAMETER ExcludeVendor
    Masque les tâches dont l'auteur/chemin ressemble à un éditeur connu.

.PARAMETER NoisePattern
    Regex (début du nom) des tâches générées par Windows/installeurs et masquées par défaut.

.PARAMETER IncludeNoise
    Réaffiche les tâches correspondant à -NoisePattern.

.PARAMETER OutputPath
    Dossier de sortie (défaut : .\Output).

.EXAMPLE
    .\Get-UserScheduledTasks.ps1
.EXAMPLE
    .\Get-UserScheduledTasks.ps1 -ComputerName srv01,srv02 -ExcludeVendor
.EXAMPLE
    .\Get-UserScheduledTasks.ps1 -SearchBase "OU=Servers,DC=contoso,DC=local"
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$SearchBase,
    [switch]$ExcludeVendor,
    [string]$NoisePattern = '^(User_Feed_Synchronization|Optimize Start Menu Cache Files|CreateExplorerShellUnelevatedTask)',
    [switch]$IncludeNoise,
    [int]$ThrottleLimit = 32,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Output'),
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# --- 1. Liste des serveurs ---------------------------------------------------
if (-not $ComputerName) {
    Import-Module ActiveDirectory
    $adParams = @{
        Filter     = 'OperatingSystem -like "*Server*" -and Enabled -eq $true'
        Properties = 'OperatingSystem'
    }
    if ($SearchBase) { $adParams.SearchBase = $SearchBase }
    $ComputerName = Get-ADComputer @adParams | Select-Object -ExpandProperty DNSHostName | Sort-Object
}
Write-Host "[*] $($ComputerName.Count) serveur(s) à interroger" -ForegroundColor Cyan

# --- 2. Collecte distante ----------------------------------------------------
$scriptBlock = {
    $sidCache = @{}
    $noise = $using:NoisePattern
    $keepNoise = $using:IncludeNoise
    $vendorPattern = '\b(Veeam|SentinelOne|Sentinel Labs|Google|Adobe|Mozilla|Dell|HP Inc|Hewlett|Lenovo|VMware|Wazuh|Fortinet|Zabbix|Nessus|Tenable|Citrix|Intel|Realtek)\b'
    Get-ScheduledTask -ErrorAction Continue |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and ($keepNoise -or $_.TaskName -notmatch $noise) } |
        ForEach-Object {
            $t = $_
            try {
            $i = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
            $author = [string]$t.Author
            $uid = [string]$t.Principal.UserId
            $sid = ''
            if ($uid) {
                if (-not $sidCache.ContainsKey($uid)) {
                    try   { $sidCache[$uid] = (New-Object System.Security.Principal.NTAccount($uid)).Translate([System.Security.Principal.SecurityIdentifier]).Value }
                    catch { $sidCache[$uid] = '' }
                }
                $sid = $sidCache[$uid]
            }
            $isVendor = ($t.TaskPath -match $vendorPattern) -or ($author -match $vendorPattern)
            [pscustomobject]@{
                Server         = $env:COMPUTERNAME
                TaskPath       = $t.TaskPath
                TaskName       = $t.TaskName
                State          = [string]$t.State
                Enabled        = $t.Settings.Enabled
                Author         = $author
                RunAs          = $uid
                RunAsSid       = $sid
                LogonType      = [string]$t.Principal.LogonType
                RunLevel       = [string]$t.Principal.RunLevel
                Triggers       = (($t.Triggers | ForEach-Object {
                                    ($_.CimClass.CimClassName -replace '^MSFT_Task|Trigger$','') +
                                    $(if ($_.StartBoundary) { " ($($_.StartBoundary))" })
                                 }) -join ' ; ')
                Actions        = (($t.Actions | ForEach-Object { ("$($_.Execute) $($_.Arguments)").Trim() }) -join ' ; ')
                LastRunTime    = $i.LastRunTime
                LastResult     = $i.LastTaskResult
                NextRunTime    = $i.NextRunTime
                Description    = $t.Description
                Category       = if ($isVendor) { 'Vendor' } else { 'Custom' }
                ReadError      = $false
            }
            } catch {
                [pscustomobject]@{
                    Server = $env:COMPUTERNAME; TaskPath = $t.TaskPath; TaskName = $t.TaskName
                    State = [string]$t.State; Enabled = $null; Author = [string]$t.Author
                    RunAs = ''; RunAsSid = ''; LogonType = ''; RunLevel = ''; Triggers = ''; Actions = ''
                    LastRunTime = $null; LastResult = $null; NextRunTime = $null
                    Description = ('Erreur de lecture : ' + $_.Exception.Message)
                    Category = 'Custom'; ReadError = $true
                }
            }
        }
}

$icParams = @{
    ComputerName  = $ComputerName
    ScriptBlock   = $scriptBlock
    ThrottleLimit = $ThrottleLimit
    ErrorAction   = 'SilentlyContinue'
    ErrorVariable = 'remoteErrors'
}
if ($Credential) { $icParams.Credential = $Credential }

$results = Invoke-Command @icParams |
    Select-Object -Property * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName

if ($ExcludeVendor) { $results = $results | Where-Object Category -eq 'Custom' }

# --- 3. Drapeaux de risque ---------------------------------------------------
$results = $results | ForEach-Object {
    $flags = @()
    # Comptes qui ne sont PAS des comptes nominatifs/à mot de passe géré à la main :
    #  - SYSTEM / LOCAL SERVICE / NETWORK SERVICE (par SID, indépendant de la langue)
    #  - comptes virtuels NT SERVICE\*, comptes machine et gMSA (nom se terminant par $)
    #  - tâches exécutées en tant que groupe (LogonType = Group)
    $builtin = (@('S-1-5-18','S-1-5-19','S-1-5-20') -contains $_.RunAsSid) -or
               ($_.RunAs -match '^(NT AUTHORITY\\)?(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$|^S-1-5-(18|19|20)$|^NT SERVICE\\')
    $managed = $_.RunAs -match '\$$'
    $named   = $_.RunAs -and -not $builtin -and -not $managed -and $_.LogonType -ne 'Group'

    # Mot de passe enregistré dans la tâche : compte réel + logon "Password" ou "InteractiveOrPassword"
    # (S4U = "ne pas stocker le mot de passe" -> non signalé)
    if ($named -and (@('Password','InteractiveOrPassword') -contains $_.LogonType)) { $flags += 'MotDePasseStocké' }
    if ($named -and $_.RunLevel -eq 'Highest')                                       { $flags += 'CompteNominatif+Highest' }
    if (@(0, 267009, 267011, 267008) -notcontains $_.LastResult -and $null -ne $_.LastResult) { $flags += 'DernierRunEnErreur' }
    if ($null -ne $_.Enabled -and -not $_.Enabled)                                   { $flags += 'Désactivée' }
    if ($_.ReadError)                                                                { $flags += 'ErreurLecture' }
    $_ | Add-Member -NotePropertyName Flags -NotePropertyValue ($flags -join ',') -PassThru
}

# --- 4. Erreurs de collecte ------------------------------------------------
$failed = $remoteErrors | ForEach-Object {
    [pscustomobject]@{
        Server = if ($_.OriginInfo.PSComputerName) { [string]$_.OriginInfo.PSComputerName }
                 elseif ($_.TargetObject -is [string]) { $_.TargetObject }
                 else { 'N/A' }
        Error  = $_.Exception.Message.Split("`n")[0]
    }
} | Sort-Object Server, Error -Unique

# --- 5. Exports --------------------------------------------------------------
$csv = Join-Path $OutputPath "ScheduledTasks_$ts.csv"
$results | Sort-Object Server, TaskPath, TaskName |
    Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -Delimiter ';'

if ($failed) {
    $failed | Export-Csv -Path (Join-Path $OutputPath "Unreachable_$ts.csv") -NoTypeInformation -Encoding UTF8 -Delimiter ';'
}

$outAbs = (Resolve-Path $OutputPath).Path
$html   = Join-Path $outAbs "ScheduledTasks_$ts.html"

function Format-Dt($d) { if ($d -and $d.Year -gt 2000) { $d.ToString('yyyy-MM-dd HH:mm') } else { '' } }

$rows = @($results | Sort-Object Server, TaskPath, TaskName | ForEach-Object {
    [pscustomobject]@{
        Server      = $_.Server
        TaskPath    = $_.TaskPath
        TaskName    = $_.TaskName
        State       = $_.State
        Enabled     = $_.Enabled
        Author      = $_.Author
        RunAs       = $_.RunAs
        LogonType   = $_.LogonType
        RunLevel    = $_.RunLevel
        Triggers    = $_.Triggers
        Actions     = $_.Actions
        LastRun     = Format-Dt $_.LastRunTime
        LastResult  = $_.LastResult
        NextRun     = Format-Dt $_.NextRunTime
        Description = $_.Description
        Category    = $_.Category
        Flags       = @($_.Flags -split ',' | Where-Object { $_ })
    }
})

$jsonRows   = (ConvertTo-Json -InputObject $rows -Depth 4 -Compress) -replace '</', '<\/'
$jsonFailed = (ConvertTo-Json -InputObject @($failed | Where-Object { $_ }) -Depth 3 -Compress) -replace '</', '<\/'
$jsonMeta   = ConvertTo-Json -Compress -InputObject @{
    Generated = (Get-Date -Format 'dd/MM/yyyy HH:mm')
    Scanned   = @($ComputerName).Count
    RunBy     = "$env:USERDOMAIN\$env:USERNAME"
    Version   = '1.1.4'
    From      = $env:COMPUTERNAME
}

$template = @'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Inventaire des tâches planifiées</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#f8f9fa; --surface:#ffffff; --border:#e5e7eb; --border-sm:#f0f1f3;
  --text-1:#111827; --text-2:#6b7280; --text-3:#9ca3af;
  --mono:"Cascadia Code","Consolas","SF Mono",monospace;
  --radius-sm:6px; --radius:10px; --radius-lg:14px;
}
body{font-family:-apple-system,"Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text-1);
  font-size:13.5px;line-height:1.5;min-height:100vh;padding:36px 28px}
.page{width:100%;max-width:none;margin:0}

/* Header */
.header{display:flex;align-items:flex-start;justify-content:space-between;gap:32px;margin-bottom:36px;
  padding-bottom:28px;border-bottom:1px solid var(--border)}
.header-brand{display:flex;align-items:center;gap:14px}
.header-icon{width:40px;height:40px;background:#111827;border-radius:var(--radius-sm);display:flex;
  align-items:center;justify-content:center;flex-shrink:0}
.header-icon svg{width:20px;height:20px;stroke:#fff;fill:none;stroke-width:1.5;stroke-linecap:round;stroke-linejoin:round}
.header-title{font-size:17px;font-weight:600;letter-spacing:-.3px}
.header-sub{font-size:12px;color:var(--text-3);margin-top:2px}
.header-meta{text-align:right;font-size:12px;color:var(--text-3);line-height:2;flex-shrink:0}
.header-meta span{color:var(--text-2);font-weight:500}

/* Stats */
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(165px,1fr));gap:12px;margin-bottom:28px}
.stat{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);padding:18px 16px;
  position:relative;overflow:hidden;cursor:pointer;transition:border-color .15s,box-shadow .15s}
.stat:hover{border-color:#d1d5db}
.stat.active{border-color:#111827;box-shadow:0 0 0 1px #111827}
.stat::before{content:"";position:absolute;top:0;left:0;right:0;height:3px;background:var(--accent,#e5e7eb)}
.stat-label{font-size:11px;color:var(--text-3);text-transform:uppercase;letter-spacing:.6px;margin-bottom:8px}
.stat-value{font-size:26px;font-weight:600;line-height:1}
.stat-sub{font-size:11px;color:var(--text-3);margin-top:4px}
.stat.blue{--accent:#3b82f6}   .stat.blue .stat-value{color:#1d4ed8}
.stat.amber{--accent:#f59e0b}  .stat.amber .stat-value{color:#b45309}
.stat.orange{--accent:#f97316} .stat.orange .stat-value{color:#c2410c}
.stat.purple{--accent:#8b5cf6} .stat.purple .stat-value{color:#6d28d9}
.stat.red{--accent:#ef4444}    .stat.red .stat-value{color:#b91c1c}
.stat.gray{--accent:#d1d5db}   .stat.gray .stat-value{color:var(--text-2)}

/* Legend */
.legend{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:24px}
.legend-item{display:flex;align-items:center;gap:8px;background:var(--surface);border:1px solid var(--border);
  border-radius:99px;padding:5px 12px 5px 6px;font-size:12px;color:var(--text-2)}

/* Section + toolbar */
.section-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:10px;gap:12px;flex-wrap:wrap}
.section-head h2{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.6px}
.count{font-size:12px;color:var(--text-3)}
.toolbar{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}
.toolbar input,.toolbar select{background:var(--surface);color:var(--text-1);border:1px solid var(--border);
  border-radius:var(--radius-sm);padding:8px 11px;font:inherit;font-size:13px;outline:none}
.toolbar input{flex:1 1 300px;min-width:220px}
.toolbar input:focus,.toolbar select:focus{border-color:#111827}
.btn{background:var(--surface);color:var(--text-1);border:1px solid var(--border);border-radius:var(--radius-sm);
  padding:8px 14px;font:inherit;font-size:13px;font-weight:500;cursor:pointer}
.btn:hover{border-color:#9ca3af}
.btn.dark{background:#111827;color:#fff;border-color:#111827}
.btn.dark:hover{background:#1f2937}

/* Table */
.table-wrapper{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-lg);
  overflow:auto;max-height:calc(100vh - 150px);min-height:200px}
table{border-collapse:separate;border-spacing:0;width:100%}
thead th{position:sticky;top:0;z-index:2;background:#fafafa;text-align:left;padding:11px 14px;font-size:11px;font-weight:600;
  text-transform:uppercase;letter-spacing:.6px;color:var(--text-2);border-bottom:1px solid var(--border);
  cursor:pointer;user-select:none;white-space:nowrap}
thead th:hover{color:var(--text-1)}
thead th::after{content:"↕";margin-left:6px;color:var(--text-3);font-size:10px}
thead th[aria-sort="ascending"]::after{content:"↑";color:var(--text-1);font-size:12px}
thead th[aria-sort="descending"]::after{content:"↓";color:var(--text-1);font-size:12px}
thead th[aria-sort="ascending"],thead th[aria-sort="descending"]{color:var(--text-1)}
tbody td{padding:11px 14px;border-bottom:1px solid var(--border-sm);vertical-align:top}
tbody tr{cursor:pointer;transition:background .1s}
tbody tr:hover{background:#fafbfc}
tbody tr:last-child td{border-bottom:0}
td.mono{font-family:var(--mono);font-size:12px}
td.path{font-family:var(--mono);font-size:11.5px;color:var(--text-2)}
td.dim{color:var(--text-2)}
td.srv{font-weight:600}
.cell{max-width:480px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;word-break:break-word}
tr.open .cell{-webkit-line-clamp:unset;max-width:800px}
.sub{color:var(--text-3);font-size:11.5px}
.nowrap{white-space:nowrap}
.no-results{text-align:center;padding:48px;color:var(--text-3)}

/* Badges */
.badge{display:inline-flex;align-items:center;gap:6px;padding:2px 10px 2px 8px;border-radius:99px;font-size:11.5px;
  font-weight:500;white-space:nowrap;border:1px solid;margin:0 4px 3px 0}
.badge-dot{width:6px;height:6px;border-radius:50%;background:currentColor;flex-shrink:0}
.b-ok{background:#ecfdf5;color:#047857;border-color:#a7f3d0}
.b-err{background:#fef2f2;color:#b91c1c;border-color:#fecaca}
.b-warn{background:#fffbeb;color:#b45309;border-color:#fde68a}
.b-info{background:#eff6ff;color:#1d4ed8;border-color:#bfdbfe}
.b-purple{background:#f5f3ff;color:#6d28d9;border-color:#ddd6fe}
.b-mute{background:#f3f4f6;color:#6b7280;border-color:#e5e7eb}

/* Unreachable */
details{margin-top:24px;background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-lg);overflow:hidden}
details summary{cursor:pointer;padding:14px 18px;font-weight:600;font-size:13px;list-style:none}
details summary::-webkit-details-marker{display:none}
details[open] summary{border-bottom:1px solid var(--border)}
details thead th{position:static;cursor:default}
details thead th::after{content:""}
details tbody tr{cursor:default}

/* Footer */
.footer{margin-top:36px;padding-top:20px;border-top:1px solid var(--border);text-align:center;font-size:11.5px;color:var(--text-3)}
.footer-brand{display:inline-flex;align-items:center;gap:8px;color:var(--text-2);font-weight:600;margin-bottom:4px}
.footer-brand .dot{width:8px;height:8px;border-radius:50%;background:#111827}

@media (max-width:900px){body{padding:24px 16px}.header{flex-direction:column}.header-meta{text-align:left}}
@media print{body{padding:0;background:#fff}.toolbar{display:none}.table-wrapper{max-height:none;overflow:visible}}
</style>
</head>
<body>
<div class="page">

<div class="header">
  <div class="header-brand">
    <div class="header-icon">
      <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>
    </div>
    <div>
      <div class="header-title">Inventaire des tâches planifiées</div>
      <div class="header-sub">Tâches personnalisées des serveurs Windows · hors \Microsoft\*</div>
    </div>
  </div>
  <div class="header-meta" id="meta"></div>
</div>

<div class="stats" id="stats"></div>

<div class="legend">
  <div class="legend-item"><span class="badge b-warn"><span class="badge-dot"></span>MotDePasseStocké</span>
    <span>Compte réel avec mot de passe enregistré (hors SYSTEM, gMSA, comptes machine/service)</span></div>
  <div class="legend-item"><span class="badge b-warn"><span class="badge-dot"></span>CompteNominatif+Highest</span>
    <span>Compte nominatif (hors gMSA/SYSTEM) · privilèges maximum</span></div>
  <div class="legend-item"><span class="badge b-err"><span class="badge-dot"></span>DernierRunEnErreur</span>
    <span>Dernier code retour différent de succès</span></div>
  <div class="legend-item"><span class="badge b-err"><span class="badge-dot"></span>ErreurLecture</span>
    <span>Tâche trouvée mais illisible : détail dans la description</span></div>
  <div class="legend-item"><span class="badge b-mute"><span class="badge-dot"></span>Désactivée</span>
    <span>Tâche présente mais désactivée</span></div>
</div>

<div class="section-head">
  <h2>Tâches planifiées</h2>
  <span class="count" id="count"></span>
</div>

<div class="toolbar">
  <input id="q" type="search" placeholder="Rechercher (serveur, tâche, compte, commande…)" autocomplete="off">
  <select id="fServer"></select>
  <select id="fCat">
    <option value="">Toutes catégories</option>
    <option value="Custom">Custom</option>
    <option value="Vendor">Éditeurs tiers</option>
  </select>
  <select id="fFlag">
    <option value="">Toutes les alertes</option>
    <option value="__any">Avec alertes</option>
    <option value="MotDePasseStocké">Mot de passe stocké</option>
    <option value="CompteNominatif+Highest">Compte nominatif + Highest</option>
    <option value="DernierRunEnErreur">Dernier run en erreur</option>
    <option value="ErreurLecture">Erreur de lecture</option>
    <option value="Désactivée">Désactivée</option>
  </select>
  <button class="btn" id="reset" type="button">Réinitialiser</button>
  <button class="btn dark" id="csv" type="button">Exporter CSV</button>
</div>

<div class="table-wrapper">
  <table>
    <thead><tr id="head"></tr></thead>
    <tbody id="body"></tbody>
  </table>
  <div class="no-results" id="empty" hidden>Aucune tâche ne correspond aux filtres.</div>
</div>

<div id="failedBox"></div>

<footer class="footer">
  <div class="footer-brand"><div class="dot"></div><span>9 Lives IT Solutions</span></div>
  <p id="foot"></p>
</footer>

</div>

<script>
const DATA   = __DATA__;
const FAILED = __FAILED__;
const META   = __META__;

const COLS = [
  {k:'Server',     t:'Serveur'},
  {k:'TaskName',   t:'Tâche'},
  {k:'TaskPath',   t:'Chemin'},
  {k:'State',      t:'État'},
  {k:'RunAs',      t:'Exécutée en tant que'},
  {k:'Triggers',   t:'Déclencheurs'},
  {k:'Actions',    t:'Actions'},
  {k:'LastRun',    t:'Dernier run'},
  {k:'LastResult', t:'Résultat'},
  {k:'NextRun',    t:'Prochain run'},
  {k:'Category',   t:'Catégorie'},
  {k:'Flags',      t:'Alertes'}
];
const FLAG_CLASS = {'MotDePasseStocké':'b-warn','CompteNominatif+Highest':'b-warn','DernierRunEnErreur':'b-err','ErreurLecture':'b-err','Désactivée':'b-mute'};

const $ = s => document.querySelector(s);
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const badge = (cls, txt) => '<span class="badge ' + cls + '"><span class="badge-dot"></span>' + esc(txt) + '</span>';
let sort = {k:'Server', dir:1};

function resultBadge(r){
  if (r === null || r === undefined) return '';
  if (r === 0)      return badge('b-ok', 'OK');
  if (r === 267009) return badge('b-info', 'En cours');
  if (r === 267008) return badge('b-info', 'Prête');
  if (r === 267011) return badge('b-mute', 'Jamais exécutée');
  return badge('b-err', '0x' + (r >>> 0).toString(16).toUpperCase());
}
function stateBadge(t){
  return badge(t.State === 'Disabled' ? 'b-mute' : t.State === 'Running' ? 'b-info' : 'b-ok', t.State);
}
const sortVal = (t, k) => k === 'Flags' ? t.Flags.length : (t[k] ?? '');

function filtered(){
  const q = $('#q').value.trim().toLowerCase();
  const s = $('#fServer').value, c = $('#fCat').value, f = $('#fFlag').value;
  return DATA.filter(t =>
    (!s || t.Server === s) &&
    (!c || t.Category === c) &&
    (!f || (f === '__any' ? t.Flags.length : t.Flags.includes(f))) &&
    (!q || [t.Server,t.TaskName,t.TaskPath,t.RunAs,t.Author,t.Triggers,t.Actions,t.Description].join(' ').toLowerCase().includes(q))
  ).sort((a,b) => {
    const x = sortVal(a, sort.k), y = sortVal(b, sort.k);
    const r = (typeof x === 'number' && typeof y === 'number') ? x - y
              : String(x).localeCompare(String(y), 'fr', {numeric:true, sensitivity:'base'});
    return r * sort.dir || a.Server.localeCompare(b.Server) || a.TaskName.localeCompare(b.TaskName);
  });
}
function renderHead(){
  $('#head').innerHTML = COLS.map(c =>
    '<th data-k="' + c.k + '" aria-sort="' + (sort.k === c.k ? (sort.dir === 1 ? 'ascending' : 'descending') : 'none') + '">' + c.t + '</th>'
  ).join('');
}
function renderBody(){
  const rows = filtered();
  $('#body').innerHTML = rows.map(t =>
    '<tr>' +
    '<td class="srv">' + esc(t.Server) + '</td>' +
    '<td><div class="cell"><b>' + esc(t.TaskName) + '</b>' + (t.Description ? '<div class="sub">' + esc(t.Description) + '</div>' : '') +
        (t.Author ? '<div class="sub">Auteur : ' + esc(t.Author) + '</div>' : '') + '</div></td>' +
    '<td class="path"><div class="cell">' + esc(t.TaskPath) + '</div></td>' +
    '<td>' + stateBadge(t) + '</td>' +
    '<td><div class="cell">' + esc(t.RunAs) + '</div><div class="sub">' + esc(t.LogonType) + ' · ' + esc(t.RunLevel) + '</div></td>' +
    '<td class="dim"><div class="cell">' + esc(t.Triggers) + '</div></td>' +
    '<td class="mono"><div class="cell">' + esc(t.Actions) + '</div></td>' +
    '<td class="mono nowrap">' + esc(t.LastRun) + '</td>' +
    '<td>' + resultBadge(t.LastResult) + '</td>' +
    '<td class="mono nowrap">' + esc(t.NextRun) + '</td>' +
    '<td>' + badge(t.Category === 'Custom' ? 'b-purple' : 'b-mute', t.Category === 'Custom' ? 'Custom' : 'Éditeur') + '</td>' +
    '<td>' + t.Flags.map(f => badge(FLAG_CLASS[f] || 'b-mute', f)).join('') + '</td>' +
    '</tr>'
  ).join('');
  $('#empty').hidden = rows.length > 0;
  $('#count').textContent = rows.length + ' / ' + DATA.length + ' tâches';
  syncStats();
  return rows;
}

const STATS = [
  {id:'all',   l:'Tâches recensées',      c:'blue',   v:() => DATA.length,                                         s:() => 'tous serveurs',                   f:{cat:'',flag:''}},
  {id:'srv',   l:'Serveurs avec tâches',  c:'gray',   v:() => new Set(DATA.map(t => t.Server)).size,               s:() => META.Scanned + ' interrogés',      f:null},
  {id:'cus',   l:'Tâches custom',         c:'purple', v:() => DATA.filter(t => t.Category === 'Custom').length,    s:() => 'hors éditeurs',                   f:{cat:'Custom',flag:''}},
  {id:'any',   l:'Avec alertes',          c:'amber',  v:() => DATA.filter(t => t.Flags.length).length,             s:() => 'à examiner',                      f:{cat:'',flag:'__any'}},
  {id:'err',   l:'Dernier run en erreur', c:'orange', v:() => DATA.filter(t => t.Flags.includes('DernierRunEnErreur')).length, s:() => 'code retour ≠ 0',      f:{cat:'',flag:'DernierRunEnErreur'}},
  {id:'fail',  l:'Erreurs de collecte', c:'red',    v:() => FAILED.length,                                       s:() => 'serveurs injoignables ou partiels',                  f:'failed'}
];
function renderStats(){
  $('#stats').innerHTML = STATS.map(s =>
    '<div class="stat ' + s.c + '" data-id="' + s.id + '"><div class="stat-label">' + s.l + '</div>' +
    '<div class="stat-value">' + s.v() + '</div><div class="stat-sub">' + s.s() + '</div></div>').join('');
}
function syncStats(){
  const c = $('#fCat').value, f = $('#fFlag').value;
  document.querySelectorAll('.stat').forEach(el => {
    const s = STATS.find(x => x.id === el.dataset.id);
    el.classList.toggle('active', !!(s.f && s.f !== 'failed' && s.f.cat === c && s.f.flag === f));
  });
}
function renderFailed(){
  if (!FAILED.length) { $('#failedBox').innerHTML = ''; return; }
  $('#failedBox').innerHTML = '<details id="failed"><summary>' + FAILED.length + ' erreur(s) de collecte (serveur injoignable ou énumération incomplète)</summary><table><thead><tr>' +
    '<th>Serveur</th><th>Erreur</th></tr></thead><tbody>' +
    FAILED.map(f => '<tr><td class="srv">' + esc(f.Server) + '</td><td class="dim">' + esc(f.Error) + '</td></tr>').join('') +
    '</tbody></table></details>';
}
function exportCsv(){
  const rows = filtered();
  const cell = v => '"' + String(v ?? '').replace(/"/g, '""') + '"';
  const keys = ['Server','TaskPath','TaskName','State','Enabled','Author','RunAs','LogonType','RunLevel','Triggers','Actions','LastRun','LastResult','NextRun','Category','Flags','Description'];
  const out = [keys.join(';')].concat(rows.map(t => keys.map(k => cell(k === 'Flags' ? t.Flags.join(',') : t[k])).join(';')));
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob(['\ufeff' + out.join('\r\n')], {type:'text/csv;charset=utf-8'}));
  a.download = 'taches_planifiees_filtrees.csv';
  a.click(); URL.revokeObjectURL(a.href);
}

// Init
$('#meta').innerHTML =
  'Généré le <span>' + esc(META.Generated) + '</span><br>' +
  'Serveurs interrogés <span>' + META.Scanned + '</span><br>' +
  'Exécuté par <span>' + esc(META.RunBy) + '</span><br>' +
  'Version <span>' + esc(META.Version) + '</span>';
$('#foot').textContent = 'Get-UserScheduledTasks v' + META.Version + ' · ' + META.Generated + ' · depuis ' + META.From;
const servers = [...new Set(DATA.map(t => t.Server))].sort((a,b) => a.localeCompare(b));
$('#fServer').innerHTML = '<option value="">Tous les serveurs</option>' + servers.map(s => '<option>' + esc(s) + '</option>').join('');
renderStats(); renderHead(); renderBody(); renderFailed();

$('#head').addEventListener('click', e => {
  const th = e.target.closest('th'); if (!th) return;
  const k = th.dataset.k;
  sort = {k, dir: sort.k === k ? -sort.dir : 1};
  renderHead(); renderBody();
});
$('#body').addEventListener('click', e => { const tr = e.target.closest('tr'); if (tr) tr.classList.toggle('open'); });
['#q','#fServer','#fCat','#fFlag'].forEach(id => $(id).addEventListener('input', renderBody));
$('#stats').addEventListener('click', e => {
  const el = e.target.closest('.stat'); if (!el) return;
  const s = STATS.find(x => x.id === el.dataset.id);
  if (s.f === 'failed') { const d = $('#failed'); if (d) { d.open = true; d.scrollIntoView({behavior:'smooth'}); } return; }
  if (!s.f) return;
  $('#fCat').value = s.f.cat; $('#fFlag').value = s.f.flag; renderBody();
});
$('#reset').addEventListener('click', () => {
  $('#q').value = ''; ['#fServer','#fCat','#fFlag'].forEach(id => $(id).value = '');
  sort = {k:'Server', dir:1}; renderHead(); renderBody();
});
$('#csv').addEventListener('click', exportCsv);
</script>
</body>
</html>
'@

$page = $template.Replace('__DATA__', $jsonRows).Replace('__FAILED__', $jsonFailed).Replace('__META__', $jsonMeta)
[System.IO.File]::WriteAllText($html, $page, (New-Object System.Text.UTF8Encoding($true)))

# --- 6. Résumé ---------------------------------------------------------------
Write-Host "[+] $($results.Count) tâche(s) trouvée(s)" -ForegroundColor Green
Write-Host "[+] Avec drapeaux : $(@($results | Where-Object Flags).Count)" -ForegroundColor Yellow
Write-Host "[!] Injoignables  : $($failed.Count)" -ForegroundColor Red
Write-Host "    CSV  : $csv"
Write-Host "    HTML : $html"

$results | Where-Object Flags | Sort-Object Server |
    Format-Table Server, TaskName, RunAs, Flags -AutoSize
