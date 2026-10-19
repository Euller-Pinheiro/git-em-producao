#!/usr/bin/env bash
# git-em-producao.sh — coloca um app que já está em produção sob controle do Git/GitHub, com segurança
#
# Uso (como root, no servidor; GIT_ORG = organização ou usuário do GitHub):
#   git-em-producao.sh descobrir                      -> mostra os serviços e as pastas de cada app
#   git-em-producao.sh preparar <repo> <pasta>        -> chave de deploy, .gitignore, varredura (NÃO envia nada)
#   git-em-producao.sh enviar   <repo> <pasta> <ver>  -> commit, etiqueta <ver> e envio ao GitHub
#
# Exemplo:
#   GIT_ORG=minha-org git-em-producao.sh preparar loja /opt/loja
#   GIT_ORG=minha-org git-em-producao.sh enviar   loja /opt/loja v1.4.0
#
# Falso alarme já conferido (ex.: valores de teste): liste o caminho, um padrão
# por linha, em <pasta>/.segredos-revisados — esse arquivo vai para o Git
# como registro da revisão. Ex.:   ^services/api/test/
#
# Garantias:
#   - "preparar" não faz commit nem envia: só mostra o que iria e onde há possível senha.
#   - "enviar" se recusa a seguir se a varredura ainda acusar algo ou se houver arquivo > 50 MB.
#   - Nada do app é alterado: só são criados .git/ e .gitignore na pasta.
set -euo pipefail

ORG="${GIT_ORG:-}"
CHAVES="${GIT_CHAVES_DIR:-/root/.ssh}"
LIMITE_MB=50

azul()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
verde() { printf '\033[1;32m%s\033[0m\n' "$*"; }
amar()  { printf '\033[1;33m%s\033[0m\n' "$*"; }
verm()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
morre() { verm "ERRO: $*"; exit 1; }

remoto() { echo "${GIT_REMOTE:-git@github-$1:$ORG/$1.git}"; }
exige_org() { [[ -n "$ORG" || -n "${GIT_REMOTE:-}" ]] || morre "defina a organização (ou usuário) do GitHub:  GIT_ORG=minha-org $0 $*"; }

MARCA='gerado por git-em-producao'
GITIGNORE_PADRAO='# --- gerado por git-em-producao: segredos e dados NUNCA entram no Git ---
.env
.env.*
!.env.example
*.sqlite3
*.sqlite3-*
*.db
# dumps de banco (migrações .sql continuam versionadas)
*dump*.sql
*backup*.sql
*bkp*.sql
*.sql.gz
*.dump
*.pem
*.key
*.pfx
*.p12
.secret
*.secret
secret.key
*.keystore
id_rsa*
id_ed25519*
# dados dos usuários
media/
uploads/
storage/
private/
backups/
dumps/
# gerados / dependências
staticfiles/
static_root/
collected_static/
node_modules/
venv/
.venv/
env/
__pycache__/
*.pyc
dist/
build/
.next/
.cache/
# logs e temporários
logs/
*.log
*.pid
*.sock
tmp/
*.tmp
*.bak
*.swp
*.zip
*.tar
*.tar.gz
*.tgz
.DS_Store'

# Padrões de possíveis segredos escritos direto no código
PADROES='(sk-ant-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[bap]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\$aact_[A-Za-z0-9_]{10,}|(SECRET_KEY|PASSWORD|PASSWD|SENHA|API_KEY|APIKEY|TOKEN|ACCESS_KEY|SECRET)["'"'"']?\s*[:=]\s*["'"'"'][^"'"'"'$\{]{8,}["'"'"'])'

descobrir() {
    azul "Serviços em execução e a pasta de cada um:"
    systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | while read -r s; do
        wd="$(systemctl show -p WorkingDirectory --value "$s" 2>/dev/null || true)"
        ex="$(systemctl show -p ExecStart --value "$s" 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' || true)"
        case "$wd$ex" in ""|/|/root) continue ;; esac
        printf '  %-40s %s  %s\n' "$s" "${wd:--}" "${ex:-}"
    done || true
    echo
    azul "Pastas em /opt e /srv:"
    ls -1d /opt/*/ /srv/*/ 2>/dev/null | sed 's/^/  /' || true
    echo
    azul "Já são repositórios Git:"
    find /opt /srv /var/www -maxdepth 3 -name .git -type d 2>/dev/null | sed 's#/.git$##; s/^/  /' || true
}

chave_de_deploy() {
    local repo="$1" k="$CHAVES/deploy_$1"
    mkdir -p "$CHAVES"; chmod 700 "$CHAVES"
    if [[ ! -f "$k" ]]; then
        ssh-keygen -q -t ed25519 -N "" -C "deploy-$repo@$(hostname)" -f "$k"
        verde "Chave de deploy criada: $k"
    fi
    if ! grep -q "^Host github-$repo\$" "$CHAVES/config" 2>/dev/null; then
        cat >> "$CHAVES/config" <<EOF

Host github-$repo
    HostName github.com
    User git
    IdentityFile $k
    IdentitiesOnly yes
EOF
        chmod 600 "$CHAVES/config"
    fi
    grep -q "^github.com " "$CHAVES/known_hosts" 2>/dev/null || ssh-keyscan -t ed25519 github.com >> "$CHAVES/known_hosts" 2>/dev/null || true
}

preparar_repo() {
    local repo="$1" dir="$2"
    cd "$dir"
    git config --global --get-all safe.directory | grep -qx "$dir" || git config --global --add safe.directory "$dir"
    if [[ ! -d .git ]]; then
        git init -q -b main
        verde "Repositório Git iniciado em $dir"
    fi
    git config user.name  "${GIT_AUTOR_NOME:-Deploy ($(hostname))}"
    git config user.email "${GIT_AUTOR_EMAIL:-deploy@$(hostname)}"
    if [[ ! -f .gitignore ]]; then
        printf '%s\n' "$GITIGNORE_PADRAO" > .gitignore
        verde ".gitignore criado"
    elif ! grep -q "$MARCA" .gitignore; then
        amar ".gitignore já existia: as regras de segurança foram acrescentadas ao final"
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' .gitignore
        printf '\n%s\n' "$GITIGNORE_PADRAO" >> .gitignore
    fi
    if git remote get-url origin >/dev/null 2>&1; then
        [[ "$(git remote get-url origin)" == "$(remoto "$repo")" ]] || amar "ATENÇÃO: este repositório já envia para $(git remote get-url origin) — não para $(remoto "$repo")"
    else
        git remote add origin "$(remoto "$repo")"
    fi
    # Remarca tudo do zero: arquivo que passou a ser ignorado sai da lista de envio.
    # (Só mexe no índice do Git; os arquivos continuam na pasta.)
    git rm -r -q -f --cached --ignore-unmatch . >/dev/null || morre "não consegui atualizar o índice do Git"
    git add -A
}

varrer() {
    # imprime achados (com o valor mascarado) e devolve 1 se houver algum
    local achados
    achados="$(git diff --cached --name-only -z | xargs -0 -r grep -nIE "$PADROES" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:.*(os\.environ|getenv\(|env\(|config\(|example\.com|placeholder|<[^>]+>|changeme|your[_-]|xxxxx)' \
        | sed -E 's/(["'"'"'][^"'"'"']{4})[^"'"'"']{4,}(["'"'"'])/\1****\2/g; s/(sk-ant-|sk-|AKIA|ghp_|github_pat_|xox.-)[A-Za-z0-9_-]{4,}/\1****/g' || true)"
    if [[ -n "$achados" && -s .segredos-revisados ]]; then
        local revisados n_rev
        revisados="$(grep -vE '^\s*(#|$)' .segredos-revisados || true)"
        if [[ -n "$revisados" ]]; then
            n_rev="$(printf '%s\n' "$achados" | grep -cE -f <(printf '%s\n' "$revisados") || true)"
            achados="$(printf '%s\n' "$achados" | grep -vE -f <(printf '%s\n' "$revisados") || true)"
            (( n_rev > 0 )) && amar "Varredura: $n_rev achado(s) ignorado(s) por já terem sido revisados (.segredos-revisados)."
        fi
    fi
    if [[ -n "$achados" ]]; then
        verm "Possíveis segredos escritos no código (valores mascarados):"
        printf '%s\n' "$achados" | sed 's/^/  /' | head -50
        return 1
    fi
    verde "Varredura: nenhum segredo aparente no que vai para o Git."
}

grandes() {
    local g
    g="$(git diff --cached --name-only -z | xargs -0 -r du -k --apparent-size 2>/dev/null | awk -v l=$((LIMITE_MB*1024)) '$1>l {printf "  %d MB  %s\n", $1/1024, $2}')"
    if [[ -n "$g" ]]; then verm "Arquivos acima de $LIMITE_MB MB (o GitHub recusa > 100 MB):"; echo "$g"; return 1; fi
}

resumo() {
    local n tam
    n="$(git diff --cached --name-only | wc -l)"
    tam="$(git diff --cached --name-only -z | xargs -0 -r du -ck --apparent-size 2>/dev/null | tail -1 | awk '{printf "%.1f MB", $1/1024}')"
    azul "Vai para o Git: $n arquivos, $tam"
    echo "  Pastas principais:"
    git diff --cached --name-only | awk -F/ '{print $1}' | sort | uniq -c | sort -rn | head -12 | sed 's/^/   /'
    echo "  Ficam de fora (ignorados) — confira se nada de código está aqui:"
    git status --ignored --porcelain | sed -n 's/^!! //p' | head -15 | sed 's/^/   /'
    local bak
    bak="$(git diff --cached --name-only | grep -iE '(^|/)[^/]*(\.bak|_bak|-bak|_backup|-backup|\.old|\.orig)[^/]*(/|$)' | sed -E 's#^(([^/]*/)*[^/]*(\.bak|_bak|-bak|_backup|-backup|\.old|\.orig)[^/]*)(/.*)?$#\1#I' | sort -u | head -15 || true)"
    if [[ -n "$bak" ]]; then
        amar "  ATENÇÃO: cópias antigas vão para o Git — mova para fora da pasta se não forem código vivo:"
        printf '%s\n' "$bak" | sed 's/^/   /'
    fi
}

[[ $EUID -eq 0 ]] || morre "rode como root"
command -v git >/dev/null || { amar "Instalando git..."; apt-get install -y -q git >/dev/null; }

acao="${1:-}"
case "$acao" in
    descobrir)
        descobrir ;;
    preparar)
        exige_org "$@"
        [[ $# -eq 3 ]] || morre "uso: $0 preparar <repo> <pasta>"
        repo="$2"; dir="$(realpath "$3")"; [[ -d "$dir" ]] || morre "pasta não existe: $dir"
        chave_de_deploy "$repo"
        preparar_repo "$repo" "$dir"
        resumo
        echo
        ok=1; varrer || ok=0; grandes || ok=0
        echo
        azul "Chave pública de deploy (cadastre no GitHub):"
        cat "$CHAVES/deploy_$repo.pub"
        echo "  -> https://github.com/$ORG/$repo/settings/keys/new"
        echo "     Title: $(hostname)   |   marque \"Allow write access\""
        echo
        if (( ok )); then verde "Pronto para enviar. Nada foi enviado ainda."
        else amar "Corrija os itens acima (ou me mande esta saída) antes de enviar. Nada foi enviado."; fi
        ;;
    enviar)
        exige_org "$@"
        [[ $# -eq 4 ]] || morre "uso: $0 enviar <repo> <pasta> <versão>"
        repo="$2"; dir="$(realpath "$3")"; ver="$4"
        [[ -d "$dir/.git" ]] || morre "rode antes: $0 preparar $repo $dir"
        cd "$dir"; git rm -r -q -f --cached --ignore-unmatch . >/dev/null || morre "não consegui atualizar o índice do Git"; git add -A
        varrer || morre "a varredura ainda acusa possíveis segredos — nada foi enviado"
        grandes || morre "há arquivos grandes demais — nada foi enviado"
        if git diff --cached --quiet && git rev-parse -q --verify HEAD >/dev/null; then
            amar "Nada mudou desde o último commit."
        else
            git commit -q -m "$repo $ver — estado em produção em $(hostname) ($(date '+%Y-%m-%d %H:%M'))"
        fi
        git rev-parse -q --verify "refs/tags/$ver" >/dev/null || git tag -a "$ver" -m "$repo $ver em produção"
        if ! git push -u origin HEAD:main --follow-tags 2>&1 | sed 's/^/  /'; then
            morre "o envio falhou — a chave de deploy foi cadastrada com 'Allow write access'?"
        fi
        git ls-remote --exit-code origin "refs/tags/$ver" >/dev/null || morre "a etiqueta $ver não chegou ao GitHub"
        verde "Enviado: https://github.com/$ORG/$repo  (versão $ver)"
        ;;
    *)
        sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
