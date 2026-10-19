#!/usr/bin/env bash
# Teste de ponta a ponta do git-em-producao.sh (o "GitHub" aqui é um repositório bare local)
# shellcheck disable=SC2034  # variáveis lidas dentro de ok() (eval)
set -uo pipefail
S="$(cd "$(dirname "$0")/.." && pwd)/git-em-producao.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_REMOTE="$T/remote.git" GIT_CHAVES_DIR="$T/chaves" HOME="$T/home"
mkdir -p "$HOME"; git init -q --bare "$T/remote.git"
f=0; ok() { if eval "$2"; then echo "  [ok]    $1"; else echo "  [FALHA] $1"; f=$((f+1)); fi; }
arvore() { git --git-dir="$T/remote.git" ls-tree -r --name-only main 2>/dev/null; }

A="$T/app"; mkdir -p "$A"/{app,media,node_modules/x,static,venv/bin}
cat > "$A/app/settings.py" <<'EOF'
import os
SECRET_KEY = 'django-insecure-abcdefghijklmnop123'
API_KEY = os.environ.get("API_KEY")
DEEPGRAM = os.getenv('DEEPGRAM_KEY')
EOF
echo 'ANTHROPIC = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV"' > "$A/app/ia.py"
echo 'const TOKEN = "<seu-token-aqui>";' > "$A/app/front.js"
echo "print('oi')" > "$A/app/views.py"
echo "SECRET=abc123456789" > "$A/.env"; echo "x" > "$A/db.sqlite3"; echo i > "$A/media/f.jpg"
echo j > "$A/node_modules/x/i.js"; echo c > "$A/static/a.css"; echo p > "$A/venv/bin/python"
echo "log" > "$A/app.log"
chown -R nobody "$A"   # pasta de outro usuário (como os apps reais)

echo "1. Segredos no código"
"$S" preparar loja "$A" > "$T/p1.out" 2>&1
ok "acusa SECRET_KEY fixo"                 'grep -q "settings.py:2" "$T/p1.out"'
ok "acusa chave sk-ant"                    'grep -q "ia.py:1" "$T/p1.out"'
ok "não acusa os.environ/getenv"           '! grep -qE "settings.py:(3|4)" "$T/p1.out"'
ok "não acusa placeholder <...>"           '! grep -q "front.js" "$T/p1.out"'
ok "valores mascarados na saída"           '! grep -q "abcdefghijklmnop123" "$T/p1.out" && ! grep -q "ABCDEFGHIJKLMNOPQRSTUV" "$T/p1.out"'
ok "mostra chave pública e link"           'grep -q "ssh-ed25519" "$T/p1.out" && grep -q "settings/keys/new" "$T/p1.out"'
ok "pasta de outro usuário funciona"       '[[ -d $A/.git ]]'
"$S" enviar loja "$A" v16 > "$T/e1.out" 2>&1; rc=$?
ok "enviar RECUSA com segredo"             '[[ $rc -ne 0 ]] && grep -q "nada foi enviado" "$T/e1.out"'
ok "nada chegou ao remoto"                 '[[ -z "$(arvore)" ]]'

echo "2. Corrigido -> envia"
sed -i "s/^SECRET_KEY = .*/SECRET_KEY = os.environ['DJANGO_SECRET_KEY']/" "$A/app/settings.py"
echo 'ANTHROPIC = os.getenv("ANTHROPIC_API_KEY")' > "$A/app/ia.py"
"$S" enviar loja "$A" v16 > "$T/e2.out" 2>&1; rc=$?
ok "enviar conclui"                        '[[ $rc -eq 0 ]]'
ok "código chegou"                         'arvore | grep -q "app/views.py"'
ok "etiqueta v16 no remoto"                'git --git-dir="$T/remote.git" rev-parse -q --verify refs/tags/v16 >/dev/null'
for x in .env db.sqlite3 media/f.jpg node_modules/x/i.js venv/bin/python app.log; do
    ok "fora do Git: $x"                   "! arvore | grep -qx '$x'"
done

echo "3. Repetir"
"$S" enviar loja "$A" v16 > "$T/e3.out" 2>&1; rc=$?
ok "repetir sem mudança não quebra"        '[[ $rc -eq 0 ]] && grep -q "Nada mudou" "$T/e3.out"'
"$S" preparar loja "$A" > /dev/null 2>&1
ok "ssh config sem entradas duplicadas"    '[[ $(grep -c "^Host github-loja$" "$GIT_CHAVES_DIR/config") -eq 1 ]]'
ok ".gitignore sem regras duplicadas"      '[[ $(grep -c "gerado por git-em-producao" "$A/.gitignore") -eq 1 ]]'
echo "nova" > "$A/app/novo.py"
"$S" enviar loja "$A" v17 > /dev/null 2>&1
ok "nova versão v17 enviada"               'arvore | grep -q "app/novo.py" && git --git-dir="$T/remote.git" rev-parse -q --verify refs/tags/v17 >/dev/null'

echo "4. .gitignore existente + arquivo gigante"
B="$T/app2"; mkdir -p "$B"; echo "*.tmp" > "$B/.gitignore"; echo "x=1" > "$B/m.py"
truncate -s 60M "$B/modelo.bin"
"$S" preparar agenda "$B" > "$T/p4.out" 2>&1
ok ".gitignore existente preservado"       'head -1 "$B/.gitignore" | grep -qx "\*.tmp"'
ok "regras acrescentadas"                  'grep -q "gerado por git-em-producao" "$B/.gitignore"'
ok "avisa arquivo > 50 MB"                 'grep -q "modelo.bin" "$T/p4.out"'
GIT_REMOTE="$T/remote2.git" "$S" enviar agenda "$B" v1 > /dev/null 2>&1; rc=$?
ok "enviar recusa arquivo gigante"         '[[ $rc -ne 0 ]]'

echo "5. App com migrações .sql, dumps e falsos alarmes revisados"
K="$T/agenda"; mkdir -p "$K"/{services/api/migrations,services/api/test,postgres/init,docs}
echo "node_modules" > "$K/.gitignore"
echo "CREATE TABLE a();" > "$K/services/api/migrations/001_init.sql"
echo "CREATE ROLE x;"    > "$K/postgres/init/01.sql"
echo "INSERT big"        > "$K/db_dump.sql"
echo "INSERT bk"         > "$K/backup-2026.sql"
echo 'export ADMIN_TOKEN="token-de-teste-123"' > "$K/services/api/test/01.sh"
echo "export const HANDOFF_TOKEN = '[TRANSBORDO]';" > "$K/services/api/reply.ts"
echo "x" > "$K/app.ts"
KR="$T/agenda-remote.git"; git init -q --bare "$KR"
GIT_REMOTE="$KR" "$S" preparar agenda "$K" > "$T/k1.out" 2>&1
ok "regra original do usuário mantida"     'head -1 "$K/.gitignore" | grep -qx node_modules'
ok "acusa os 2 achados (sem revisão)"      'grep -q "test/01.sh" "$T/k1.out" && grep -q "reply.ts" "$T/k1.out"'
GIT_REMOTE="$KR" "$S" enviar agenda "$K" v55 > /dev/null 2>&1; rc=$?
ok "sem revisão: recusa enviar"            '[[ $rc -ne 0 ]]'
printf '# conferido: valores de teste e marcador de texto\n^services/api/test/\n^services/api/reply\\.ts:\n' > "$K/.segredos-revisados"
GIT_REMOTE="$KR" "$S" enviar agenda "$K" v55 > "$T/k2.out" 2>&1; rc=$?
ok "com revisão: envia"                    '[[ $rc -eq 0 ]] && grep -q "2 achado(s) ignorado(s)" "$T/k2.out"'
kt() { git --git-dir="$KR" ls-tree -r --name-only main; }
ok "migração .sql versionada"              'kt | grep -qx services/api/migrations/001_init.sql'
ok "postgres/init .sql versionado"         'kt | grep -qx postgres/init/01.sql'
ok "dump .sql fora"                        '! kt | grep -q db_dump.sql && ! kt | grep -q backup-2026.sql'
ok "lista de revisados vai para o Git"     'kt | grep -qx .segredos-revisados'
echo 'SENHA = "senha-real-nova-123"' > "$K/novo.py"
GIT_REMOTE="$KR" "$S" enviar agenda "$K" v56 > /dev/null 2>&1; rc=$?
ok "segredo NOVO fora da lista ainda bloqueia" '[[ $rc -ne 0 ]]'

echo "6. .secret e arquivo que passa a ser ignorado depois de já marcado"
F="$T/painel"; mkdir -p "$F"; echo "x=1" > "$F/painel.py"; head -c 64 /dev/urandom | base64 > "$F/.secret"
echo "trava" > "$F/cron.lock"
FR="$T/painel-remote.git"; git init -q --bare "$FR"
# repo já marcado antes de existir o .gitignore
git -C "$F" init -q -b main; git -C "$F" add -A
GIT_REMOTE="$FR" "$S" preparar painel "$F" > /dev/null 2>&1
ok ".secret fora pela regra padrão"         '! git -C "$F" diff --cached --name-only | grep -qx .secret'
ok ".lock ainda marcado (sem regra)"        'git -C "$F" diff --cached --name-only | grep -qx cron.lock'
echo "*.lock" >> "$F/.gitignore"
GIT_REMOTE="$FR" "$S" enviar painel "$F" v27 > /dev/null 2>&1
ft() { git --git-dir="$FR" ls-tree -r --name-only main; }
ok "arquivo ignorado depois sai do envio"   '! ft | grep -qx cron.lock && ft | grep -qx painel.py'
ok "arquivos continuam na pasta"            '[[ -f $F/.secret && -f $F/cron.lock ]]'
echo "7. origin já apontando para outro lugar"
V="$T/site"; mkdir -p "$V"; echo a > "$V/a.py"; git -C "$V" init -q -b main; git -C "$V" remote add origin /tmp/outro.git
"$S" preparar site "$V" > "$T/v.out" 2>&1
ok "avisa origin diferente"                 'grep -q "ATENÇÃO: este repositório já envia para /tmp/outro.git" "$T/v.out"'

echo "8. Branch master e cópias .bak"
M="$T/site2"; mkdir -p "$M/.bak-20260901/sub" "$M/app"; echo a > "$M/app/a.py"; echo b > "$M/.bak-20260901/sub/x.py"
git -C "$M" init -q -b master
MR="$T/site2-remote.git"; git init -q --bare "$MR"
GIT_REMOTE="$MR" "$S" preparar site "$M" > "$T/m.out" 2>&1
ok "avisa pasta .bak que vai para o Git"     'grep -q "cópias antigas" "$T/m.out" && grep -q "^ *\.bak-20260901$" "$T/m.out"'
GIT_REMOTE="$MR" "$S" enviar site "$M" v8 > "$T/m2.out" 2>&1; rc=$?
ok "branch master chega como main"          '[[ $rc -eq 0 ]] && git --git-dir="$MR" ls-tree -r --name-only main | grep -qx app/a.py'
ok "etiqueta v8 no remoto"                  'git --git-dir="$MR" rev-parse -q --verify refs/tags/v8 >/dev/null'

echo
(( f == 0 )) && echo "Todos os testes passaram." || { echo "$f falha(s)"; exit 1; }
