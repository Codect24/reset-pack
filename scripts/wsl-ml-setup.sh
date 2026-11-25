#!/usr/bin/env bash
# wsl-ml-setup.sh -- provisioning deep learning de la distro WSL2 (Reset Pack, lot 3).
# Reference : SYSTEME-OMEN-35L.md, section 5. Lance depuis Windows par modules/14-ml.ps1 :
#   wsl -d Ubuntu --cd ~ --exec bash /mnt/c/.../scripts/wsl-ml-setup.sh --smoke-test --env 'HF_HOME=$HOME/ml/hf' ...
#
# Ce qu'il fait (idempotent : relancable a volonte, ne refait que ce qui manque) :
#   - paquets apt de base s'ils manquent (build-essential, git, python3-venv, curl, ca-certificates) ;
#   - uv (installeur officiel astral, dans ~/.local/bin) ;
#   - dossiers ~/ml/hf et ~/ml/torch (caches dans l'ext4, jamais sur /mnt/c : le pont 9p est trop lent) ;
#   - bloc balise dans ~/.bashrc (HF_HOME, TORCH_HOME, PATH), reecrit a chaque run.
#
# Regles NVIDIA dans WSL (a ne pas assouplir) :
#   - le pilote vient de WINDOWS (NVIDIA App) et projette libcuda dans /usr/lib/wsl/lib :
#     AUCUN pilote NVIDIA Linux ici, il casserait cette projection ;
#   - pas de toolkit CUDA systeme par defaut (les wheels torch embarquent le runtime et cuDNN) ;
#     --with-cuda-toolkit installe UNIQUEMENT cuda-toolkit-12-8 depuis le depot NVIDIA wsl-ubuntu
#     (jamais le meta-paquet complet, qui tire un pilote) ; garde-fou : assert_allowed_pkg ;
#   - Blackwell (sm_120) : torch >= 2.7 en wheels cu128.
#
# Le fichier doit rester en LF (bash refuse 'set -euo pipefail\r') : 14-ml.ps1 en fait une copie LF
# temporaire s'il a ete extrait en CRLF par git (core.autocrlf=true).
set -euo pipefail

BEGIN_MARK='# >>> reset-pack ml >>>'
END_MARK='# <<< reset-pack ml <<<'
APT_PKGS=(build-essential git python3-venv curl ca-certificates)
CUDA_TOOLKIT_PKG='cuda-toolkit-12-8'
CUDA_TOOLKIT_BIN='/usr/local/cuda-12.8/bin'
CUDA_KEYRING_URL='https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb'
TORCH_INDEX_URL='https://download.pytorch.org/whl/cu128'
UV_INSTALL_URL='https://astral.sh/uv/install.sh'
SMOKE_VENV="$HOME/ml/.smoke"

# Variables exportees par le bloc ~/.bashrc (valeurs LITTERALES : '$HOME' est developpe a l'ouverture du shell).
# Surchargees / completees par --env NOM=VALEUR (14-ml.ps1 passe celles de storage-layout.json > wsl.env).
# (Pas de HF_HUB_ENABLE_HF_TRANSFER : sans le paquet hf_transfer, un huggingface_hub ancien échoue ; hf_xet suffit.)
ENV_NAMES=(HF_HOME TORCH_HOME)
ENV_VALUES=('$HOME/ml/hf' '$HOME/ml/torch')

DRY_RUN=0
WITH_CUDA=0
SMOKE=0
SMOKE_ONLY=0
NON_INTERACTIVE=0
SUDO=()
SUDO_READY=0
APT_UPDATED=0
UV_BIN=''

log()  { printf '  -> %s\n' "$*"; }
ok()   { printf '  ok  %s\n' "$*"; }
warn() { printf '  !!  %s\n' "$*" >&2; }
dry()  { printf '  [dry] %s\n' "$*"; }
die()  { printf '  XX  %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage : wsl-ml-setup.sh [options]
  --smoke-test         provisioning + venv ~/ml/.smoke (uv) + torch cu128 + test CUDA (code 2 si CUDA indisponible)
  --smoke-only         test CUDA seul, avec le venv ~/ml/.smoke existant, sans rien installer (code 3 si absent)
  --with-cuda-toolkit  ajoute cuda-toolkit-12-8 (depot NVIDIA wsl-ubuntu) : pour compiler des kernels seulement
  --env NOM=VALEUR     variable exportee par le bloc ~/.bashrc (repetable ; '$HOME' reste litteral)
  --non-interactive    sudo -n : si un mot de passe est requis, les paquets apt sont sautes
  --dry-run            affiche ce qui serait fait, n'execute rien
  -h, --help           cette aide
Codes de sortie : 0 OK, 1 erreur, 2 CUDA indisponible, 3 venv/torch absent, 64 usage.
EOF
}

die_usage() { printf '  XX  %s\n' "$*" >&2; usage >&2; exit 64; }

# run CMD... : execute, ou affiche seulement en --dry-run.
run() {
    if (( DRY_RUN )); then dry "$*"; return 0; fi
    "$@"
}

set_env_kv() {
    local kv="$1" name value i
    [[ "$kv" == *=* ]] || die_usage "--env attend NOM=VALEUR (recu : '$kv')"
    name="${kv%%=*}"
    value="${kv#*=}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die_usage "--env : nom de variable invalide '$name'"
    # La valeur est ecrite entre guillemets dans ~/.bashrc : on refuse ce qui pourrait en sortir.
    case "$value" in
        *'"'* | *'\'* | *'`'* | *'$('* | *$'\n'*) die_usage "--env $name : caracteres interdits dans la valeur" ;;
    esac
    for i in "${!ENV_NAMES[@]}"; do
        if [[ "${ENV_NAMES[$i]}" == "$name" ]]; then ENV_VALUES[i]="$value"; return 0; fi
    done
    ENV_NAMES+=("$name")
    ENV_VALUES+=("$value")
}

env_value() {
    local i
    for i in "${!ENV_NAMES[@]}"; do
        if [[ "${ENV_NAMES[$i]}" == "$1" ]]; then printf '%s' "${ENV_VALUES[$i]}"; return 0; fi
    done
    return 1
}

# '$HOME/ml/hf' -> '/home/<toi>/ml/hf'
expand_home() {
    local v="$1"
    v="${v//\$\{HOME\}/$HOME}"
    v="${v//\$HOME/$HOME}"
    printf '%s' "$v"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --smoke-test)        SMOKE=1; shift ;;
            --smoke-only)        SMOKE_ONLY=1; shift ;;
            --with-cuda-toolkit) WITH_CUDA=1; shift ;;
            --non-interactive)   NON_INTERACTIVE=1; shift ;;
            --dry-run)           DRY_RUN=1; shift ;;
            --env)               [[ $# -ge 2 ]] || die_usage "--env sans valeur"; set_env_kv "$2"; shift 2 ;;
            --env=*)             set_env_kv "${1#--env=}"; shift ;;
            -h | --help)         usage; exit 0 ;;
            *)                   die_usage "option inconnue : $1" ;;
        esac
    done
    # Pas de terminal (sortie capturee) : sudo ne pourrait pas demander de mot de passe.
    if [[ ! -t 0 ]]; then NON_INTERACTIVE=1; fi
}

is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Garde-fou : le pilote NVIDIA vient de Windows. Refuse tout paquet qui en installerait un dans WSL.
assert_allowed_pkg() {
    case "$1" in
        cuda | cuda=* | cuda:* | cuda-drivers* | nvidia-driver* | nvidia-dkms* | nvidia-utils* | libnvidia-compute*)
            die "paquet interdit dans WSL : '$1' (le pilote NVIDIA vient de Windows ; toolkit : $CUDA_TOOLKIT_PKG uniquement)" ;;
    esac
}

ensure_sudo() {
    if (( SUDO_READY )); then return 0; fi
    if [[ "$(id -u)" -eq 0 ]]; then SUDO=(); SUDO_READY=1; return 0; fi
    SUDO=(sudo)
    # Simulation : sudo n'est JAMAIS appele (hors WSL, 'sudo' peut etre celui de Windows -> UAC).
    if (( DRY_RUN )); then SUDO_READY=1; return 0; fi
    command -v sudo >/dev/null 2>&1 || { warn "sudo introuvable"; return 1; }
    if (( NON_INTERACTIVE )); then
        if sudo -n true 2>/dev/null; then
            SUDO=(sudo -n)
        else
            warn "sudo demande un mot de passe et le mode est non interactif."
            return 1
        fi
    else
        log "sudo va peut-etre demander ton mot de passe Linux"
    fi
    SUDO_READY=1
}

apt_update_once() {
    if (( APT_UPDATED )); then return 0; fi
    run "${SUDO[@]}" apt-get update
    APT_UPDATED=1
}

apt_install() {
    local p
    for p in "$@"; do assert_allowed_pkg "$p"; done
    run "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

check_environment() {
    if is_wsl; then
        ok "WSL detecte (${WSL_DISTRO_NAME:-distro inconnue})"
    elif (( DRY_RUN )); then
        warn "pas dans WSL : simulation seulement"
    else
        die "ce script doit tourner DANS WSL (wsl -d Ubuntu --exec bash ...)"
    fi
    if compgen -G '/usr/lib/wsl/lib/libcuda.so*' >/dev/null; then
        ok "libcuda projetee par le pilote Windows (/usr/lib/wsl/lib)"
    else
        warn "libcuda absente de /usr/lib/wsl/lib : pilote NVIDIA Windows manquant (NVIDIA App) ou distro en WSL1"
    fi
    # Un pilote Linux installe a la main casse la projection : on le signale, sans le retirer d'office.
    local bad
    bad="$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
        | awk '$NF == "installed" && ($1 ~ /^nvidia-driver/ || $1 ~ /^cuda-drivers/ || $1 == "cuda") { print $1 }' \
        || true)"
    if [[ -n "$bad" ]]; then
        warn "paquet(s) pilote NVIDIA Linux installe(s) dans WSL : ${bad//$'\n'/ } -> ils cassent libcuda ; retire-les a la main (sudo apt-get purge ...)"
    fi
}

install_apt_deps() {
    local p missing=()
    for p in "${APT_PKGS[@]}"; do
        if ! pkg_installed "$p"; then missing+=("$p"); fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "paquets apt deja presents (${APT_PKGS[*]})"
        return 0
    fi
    log "paquets apt manquants : ${missing[*]}"
    if ! ensure_sudo; then
        warn "paquets apt sautes (${missing[*]}) : relance sans --non-interactive (.\\reset.ps1 -Only ml sans -Auto)"
        return 0
    fi
    apt_update_once
    apt_install "${missing[@]}"
}

find_uv() {
    if command -v uv >/dev/null 2>&1; then command -v uv; return 0; fi
    if [[ -x "$HOME/.local/bin/uv" ]]; then printf '%s\n' "$HOME/.local/bin/uv"; return 0; fi
    return 1
}

install_uv() {
    local found
    if found="$(find_uv)"; then
        UV_BIN="$found"
        ok "uv deja installe ($UV_BIN)"
        return 0
    fi
    UV_BIN="$HOME/.local/bin/uv"
    if (( DRY_RUN )); then
        dry "curl -LsSf $UV_INSTALL_URL | env UV_INSTALL_DIR=$HOME/.local/bin UV_NO_MODIFY_PATH=1 sh"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "curl absent : impossible d'installer uv"
    log "installation de uv (installeur officiel astral)"
    curl -LsSf "$UV_INSTALL_URL" | env UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh
    [[ -x "$UV_BIN" ]] || die "uv introuvable apres installation ($UV_BIN)"
    ok "uv installe ($("$UV_BIN" --version))"
}

create_dirs() {
    local name raw dir
    for name in HF_HOME TORCH_HOME; do
        raw="$(env_value "$name" || true)"
        [[ -n "$raw" ]] || continue
        dir="$(expand_home "$raw")"
        if [[ "$dir" == *'$'* ]]; then warn "$name=$raw : variable non resolue, dossier non cree"; continue; fi
        if [[ -d "$dir" ]]; then ok "$dir existe"; else run mkdir -p "$dir"; fi
    done
    if [[ ! -d "$HOME/ml" ]]; then run mkdir -p "$HOME/ml"; fi
}

render_block() {
    local i
    printf '%s\n' "$BEGIN_MARK"
    printf '%s\n' "# Gere par le Reset Pack (scripts/wsl-ml-setup.sh) : bloc reecrit a chaque execution, ne pas l'editer."
    for i in "${!ENV_NAMES[@]}"; do
        printf 'export %s="%s"\n' "${ENV_NAMES[$i]}" "${ENV_VALUES[$i]}"
    done
    printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
    printf 'if [ -d %s ]; then case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac; fi\n' \
        "$CUDA_TOOLKIT_BIN" "$CUDA_TOOLKIT_BIN" "$CUDA_TOOLKIT_BIN"
    printf '%s\n' "$END_MARK"
}

# Remplace le bloc balise en place (ou l'ajoute en fin de fichier) : jamais de doublon.
write_bashrc_block() {
    local rc="$HOME/.bashrc" nb ne blk tmp
    nb="$(grep -cxF -- "$BEGIN_MARK" "$rc" 2>/dev/null || true)"
    ne="$(grep -cxF -- "$END_MARK" "$rc" 2>/dev/null || true)"
    if [[ "${nb:-0}" != "${ne:-0}" ]]; then
        die "~/.bashrc : balises reset-pack desequilibrees (${nb:-0} debut / ${ne:-0} fin) : corrige-le a la main"
    fi
    blk="$(mktemp)"
    tmp="$(mktemp)"
    render_block >"$blk"
    if [[ -f "$rc" ]]; then
        awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v f="$blk" '
            function emit(  l) { while ((getline l < f) > 0) print l; close(f) }
            $0 == b { if (!done) { emit(); done = 1 }; skip = 1; next }
            skip    { if ($0 == e) skip = 0; next }
                    { print }
            END     { if (!done) emit() }
        ' "$rc" >"$tmp"
    else
        cat "$blk" >"$tmp"
    fi
    if [[ -f "$rc" ]] && cmp -s "$tmp" "$rc"; then
        ok "~/.bashrc : bloc reset-pack deja a jour"
    elif (( DRY_RUN )); then
        dry "ecrire le bloc reset-pack dans ~/.bashrc (${ENV_NAMES[*]}, PATH)"
    else
        cat "$tmp" >"$rc"   # cat > et non mv : garde droits, proprietaire et eventuel lien symbolique
        ok "~/.bashrc : bloc reset-pack ecrit (${ENV_NAMES[*]}, PATH)"
    fi
    rm -f "$blk" "$tmp"
}

install_cuda_toolkit() {
    if pkg_installed "$CUDA_TOOLKIT_PKG"; then
        ok "$CUDA_TOOLKIT_PKG deja installe"
        return 0
    fi
    ensure_sudo || die "toolkit CUDA : sudo indisponible (relance sans --non-interactive)"
    if pkg_installed cuda-keyring; then
        ok "depot NVIDIA wsl-ubuntu deja configure (cuda-keyring)"
    elif (( DRY_RUN )); then
        dry "curl -fsSL -o <tmp>/cuda-keyring.deb $CUDA_KEYRING_URL"
        dry "${SUDO[*]} dpkg -i <tmp>/cuda-keyring.deb"
        APT_UPDATED=0
    else
        local tmpd
        tmpd="$(mktemp -d)"
        curl -fsSL -o "$tmpd/cuda-keyring.deb" "$CUDA_KEYRING_URL" || die "telechargement de cuda-keyring impossible"
        "${SUDO[@]}" dpkg -i "$tmpd/cuda-keyring.deb" || die "dpkg -i cuda-keyring a echoue"
        rm -rf "$tmpd"
        APT_UPDATED=0   # nouveau depot : apt-get update obligatoire
    fi
    apt_update_once
    apt_install "$CUDA_TOOLKIT_PKG"
    if (( ! DRY_RUN )); then ok "$CUDA_TOOLKIT_PKG installe (nvcc dans $CUDA_TOOLKIT_BIN, ajoute au PATH par le bloc ~/.bashrc)"; fi
}

smoke_prepare() {
    local uv="${UV_BIN:-uv}"
    if [[ -x "$SMOKE_VENV/bin/python" ]]; then
        ok "venv smoke-test present ($SMOKE_VENV)"
    else
        run "$uv" venv "$SMOKE_VENV" || die "uv venv $SMOKE_VENV a echoue"
    fi
    log "torch en wheels cu128 (Blackwell sm_120) : ~3 Go au premier passage, rien ensuite"
    run "$uv" pip install --python "$SMOKE_VENV/bin/python" torch --index-url "$TORCH_INDEX_URL" \
        || die "uv pip install torch (index cu128) a echoue"
}

# Lignes 'RESETPACK_SMOKE cle=valeur' : lues par scripts/ml-smoke-test.ps1.
smoke_run() {
    local py="$SMOKE_VENV/bin/python" rc=0
    if (( DRY_RUN )); then
        dry "$py - (torch.__version__, cuda.is_available, nom du GPU, capability, matmul sur cuda)"
        return 0
    fi
    if [[ ! -x "$py" ]]; then
        printf 'RESETPACK_SMOKE status=no-venv\n'
        warn "venv smoke-test absent ($SMOKE_VENV) : lance le provisioning (.\\reset.ps1 -Only ml)"
        return 3
    fi
    "$py" - <<'PY' || rc=$?
import sys

def out(key, value):
    print("RESETPACK_SMOKE %s=%s" % (key, value), flush=True)

try:
    import torch
except Exception as exc:
    out("status", "no-torch")
    out("error", "import torch: %s" % exc)
    sys.exit(3)

out("torch", torch.__version__)
out("torch_cuda", torch.version.cuda)
available = torch.cuda.is_available()
out("cuda", int(available))
if not available:
    print("CUDA indisponible : verifie le pilote Windows (nvidia-smi) et qu'aucun pilote Linux n'est installe dans WSL.")
    sys.exit(2)

major, minor = torch.cuda.get_device_capability(0)
out("gpu", torch.cuda.get_device_name(0))
out("capability", "%d.%d" % (major, minor))
arch = "sm_%d%d" % (major, minor)
arch_list = torch.cuda.get_arch_list()
out("arch_list", ",".join(arch_list))
if arch not in arch_list:
    print("ATTENTION : %s absent des kernels de ce torch -> 'no kernel image' probable (torch >= 2.7 cu128 requis)." % arch)

try:
    a = torch.randn(2048, 2048, device="cuda")
    b = torch.randn(2048, 2048, device="cuda")
    c = a @ b
    torch.cuda.synchronize()
    finite = bool(torch.isfinite(c).all().item())
except Exception as exc:
    out("matmul", 0)
    out("error", (str(exc).splitlines() or [type(exc).__name__])[0])
    sys.exit(2)
out("matmul", int(finite))
sys.exit(0 if finite else 2)
PY
    if [[ $rc -eq 0 ]]; then ok "smoke-test torch : CUDA OK"; else warn "smoke-test torch : ECHEC (code $rc)"; fi
    return "$rc"
}

main() {
    local rc=0
    # Tout echec inattendu (apt, curl, awk...) sort en 1 : les codes 2 (CUDA KO) et 3 (venv/torch absent)
    # restent reserves au smoke-test, que 14-ml.ps1 et ml-smoke-test.ps1 interpretent.
    set -o errtrace
    trap 'exit 1' ERR
    parse_args "$@"
    if (( DRY_RUN )); then log "SIMULATION (--dry-run) : rien n'est execute"; fi
    if (( SMOKE_ONLY )); then
        smoke_run || rc=$?
        exit "$rc"
    fi
    check_environment
    install_apt_deps
    install_uv
    export PATH="$HOME/.local/bin:$PATH"
    create_dirs
    write_bashrc_block
    if (( WITH_CUDA )); then install_cuda_toolkit; fi
    if (( SMOKE )); then
        smoke_prepare
        smoke_run || rc=$?
    fi
    if [[ $rc -eq 0 ]]; then ok "provisioning ML termine"; fi
    exit "$rc"
}

# Source (tests) : fonctions seulement. Execute : provisioning.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
