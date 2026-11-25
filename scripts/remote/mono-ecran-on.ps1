# mono-ecran-on.ps1 : commande « do » du global_prep_cmd de Sunshine (début de stream).
# Sauvegarde l'agencement des écrans puis désactive tous ceux que Sunshine ne capte pas (keepMonitor).
# Lancé en session 0 / SYSTEM : relais vers la tâche planifiée ResetPack-MonoEcranOn (contexte utilisateur).
# Sort TOUJOURS en 0 : un échec ne doit pas empêcher Sunshine d'ouvrir la session.
# Journal : %LOCALAPPDATA%\ResetPack\remote.log
[CmdletBinding()]
param(
    [string]$KeepMonitor,   # surcharge ponctuelle de keepMonitor (settings.json)
    [switch]$NoRelay        # posé par la tâche planifiée : ne pas relayer une seconde fois
)
$script:MonoCaller = 'mono-ecran-on'
try {
    . (Join-Path $PSScriptRoot 'mono-ecran-commun.ps1')
    $settings = Get-MonoSetting -Dir $PSScriptRoot
    if ($KeepMonitor) { $settings.keepMonitor = $KeepMonitor }
    if ((-not $NoRelay) -and (Test-NeedsRelay)) {
        Invoke-MonoRelay -TaskName ([string]$settings.taskOn)
    } else {
        $result = Invoke-MonoEcranOn -Settings $settings
        Write-MonoLog "terminé : $result"
    }
} catch {
    try { Write-MonoLog "erreur inattendue : $($_.Exception.Message)" 'ERREUR' } catch { Write-Verbose 'journal indisponible' }
}
exit 0
