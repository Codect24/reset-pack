# mono-ecran-off.ps1 : commande « undo » du global_prep_cmd de Sunshine (fin de stream).
# Réactive les écrans désactivés par mono-ecran-on puis recharge l'agencement exact (/LoadConfig).
# Sans mono-écran engagé (pas d'état mémorisé), ne touche à rien.
# Lancé en session 0 / SYSTEM : relais vers la tâche planifiée ResetPack-MonoEcranOff (contexte utilisateur).
# Sort TOUJOURS en 0. Journal : %LOCALAPPDATA%\ResetPack\remote.log
[CmdletBinding()]
param(
    [switch]$NoRelay        # posé par la tâche planifiée : ne pas relayer une seconde fois
)
$script:MonoCaller = 'mono-ecran-off'
try {
    . (Join-Path $PSScriptRoot 'mono-ecran-commun.ps1')
    $settings = Get-MonoSetting -Dir $PSScriptRoot
    if ((-not $NoRelay) -and (Test-NeedsRelay)) {
        Invoke-MonoRelay -TaskName ([string]$settings.taskOff)
    } else {
        $result = Invoke-MonoEcranOff -Settings $settings
        Write-MonoLog "terminé : $result"
    }
} catch {
    try { Write-MonoLog "erreur inattendue : $($_.Exception.Message)" 'ERREUR' } catch { Write-Verbose 'journal indisponible' }
}
exit 0
