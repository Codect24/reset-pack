# reactiver-ecrans.ps1 : SECOURS « réactiver tous les écrans ».
# /enable de tous les écrans (même sans état mémorisé), puis tentative de /LoadConfig de l'agencement sauvegardé.
# À lancer à la demande, par exemple depuis Parsec ou une session tailscale ssh :
#     schtasks /run /tn ResetPack-ReactiverEcrans
# Lancé en session 0 / SYSTEM : relais automatique vers cette tâche (contexte utilisateur).
# Sort TOUJOURS en 0. Journal : %LOCALAPPDATA%\ResetPack\remote.log
[CmdletBinding()]
param(
    [switch]$NoRelay        # posé par la tâche planifiée : ne pas relayer une seconde fois
)
$script:MonoCaller = 'reactiver-ecrans'
try {
    . (Join-Path $PSScriptRoot 'mono-ecran-commun.ps1')
    $settings = Get-MonoSetting -Dir $PSScriptRoot
    if ((-not $NoRelay) -and (Test-NeedsRelay)) {
        Invoke-MonoRelay -TaskName ([string]$settings.taskRescue)
    } else {
        $result = Invoke-MonoEcranOff -Settings $settings -Rescue
        Write-MonoLog "terminé : $result"
    }
} catch {
    try { Write-MonoLog "erreur inattendue : $($_.Exception.Message)" 'ERREUR' } catch { Write-Verbose 'journal indisponible' }
}
exit 0
