# git-em-producao

[![Testes](https://github.com/Euller-Pinheiro/git-em-producao/actions/workflows/testes.yml/badge.svg)](https://github.com/Euller-Pinheiro/git-em-producao/actions/workflows/testes.yml)
![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white)
![Licença MIT](https://img.shields.io/badge/licen%C3%A7a-MIT-green)

**[English below](#english)**

Coloca no Git e no GitHub um sistema que **já está rodando em produção** e nunca foi versionado, sem deixar escapar senha, banco de dados ou arquivo de usuário.

É a situação real de muita empresa pequena: o app foi para o servidor por zip ou por cópia, funciona, e o único "histórico" são pastas `app.bak-2026-09-30`. Este script faz a passagem com segurança, um app por vez, em duas etapas: primeiro mostra o que iria, e só depois envia.

Usei este script para versionar os sistemas da [ESX Tecnologia](https://esxtecnologia.com): ERP, CRM, helpdesk, plataforma de ensino e outros. Os testes reproduzem os problemas que apareceram nessa migração.

## O que ele evita

| Risco | O que o script faz |
|---|---|
| `.env`, chave privada, certificado ou `.secret` irem para o GitHub | `.gitignore` de segurança aplicado antes do primeiro commit. Se o `.gitignore` já existir, as regras são acrescentadas ao final. |
| Senha escrita direto no código | Varredura com padrões de chaves (OpenAI/Anthropic, AWS, GitHub, Slack) e de atribuições como `SECRET_KEY = '...'`. Ela ignora `os.environ`, `getenv` e exemplos. Se achar algo, **o envio é recusado**. A saída mostra os valores mascarados. |
| Falso alarme bloquear para sempre | Achados conferidos vão para `.segredos-revisados`, um padrão por linha. O arquivo fica no Git como registro da revisão. Um segredo **novo** continua bloqueando. |
| Dump do banco ir junto, mas as migrações ficarem de fora | Ignora `*dump*.sql`, `*backup*.sql`, `*.sql.gz` e SQLite. Mantém `migrations/*.sql` e scripts de schema. |
| Arquivo gigante travar o push | Recusa qualquer arquivo acima de 50 MB, medido pelo tamanho real, inclusive arquivos esparsos. |
| Arquivo marcado **antes** de a regra existir continuar indo | Remarca o índice do zero a cada envio. Só o índice muda; os arquivos ficam na pasta. |
| Pastas `.bak-*` e `_backup` entrarem sem ninguém notar | Avisa no resumo, antes de enviar. |
| Branch `master` de um lado e `main` do outro | Envia a branch atual como `main`. |
| Chave pessoal de SSH dentro do servidor | Gera uma **deploy key** por repositório, com escopo só naquele repo. |

## Uso

```bash
sudo cp git-em-producao.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/git-em-producao.sh
export GIT_ORG=minha-org          # organização ou usuário do GitHub

git-em-producao.sh descobrir                       # serviços em execução e a pasta de cada app
git-em-producao.sh preparar loja /opt/loja         # chave de deploy, .gitignore e varredura (não envia nada)
#   -> cadastre a chave pública mostrada em  github.com/minha-org/loja/settings/keys/new  ("Allow write access")
git-em-producao.sh enviar   loja /opt/loja v1.4.0  # commit, etiqueta e envio
```

O `preparar` termina com um resumo do que vai e do que fica de fora. Se algo de código aparecer entre os ignorados, ajuste o `.gitignore` e rode o `preparar` de novo. Ele pode ser repetido quantas vezes for preciso, sem duplicar regras nem entradas de SSH.

Para uma nova versão do mesmo app, basta rodar `enviar loja /opt/loja v1.5.0`.

### Variáveis

| Variável | Para quê |
|---|---|
| `GIT_ORG` | organização ou usuário do GitHub (obrigatória, a não ser que `GIT_REMOTE` seja usada) |
| `GIT_REMOTE` | endereço completo do remoto, para GitLab, Gitea etc. |
| `GIT_CHAVES_DIR` | onde ficam as chaves de deploy e o `ssh config` (padrão `/root/.ssh`) |
| `GIT_AUTOR_NOME`, `GIT_AUTOR_EMAIL` | autor dos commits feitos no servidor |

## Testes

[`tests/test.sh`](tests/test.sh) roda o fluxo completo contra um repositório *bare* local, no papel do GitHub. São 43 verificações, entre elas:

- segredos são detectados e mascarados;
- o envio é recusado enquanto houver segredo;
- migrações entram e dumps ficam de fora;
- a lista de revisados funciona;
- arquivo ignorado depois de marcado sai do envio;
- a branch `master` chega como `main`.

O GitHub Actions roda o ShellCheck e os testes a cada push.

```bash
sudo ./tests/test.sh
```

## Autor

**Euller Pinheiro**, Diretor Técnico da [ESX Tecnologia](https://esxtecnologia.com), empresa de TI gerenciada, infraestrutura e desenvolvimento em São Paulo.

Tem sistema em produção sem versionamento nem backup? [Fale com a ESX](https://esxtecnologia.com).

---

<a name="english"></a>
## English

Puts an application that is **already running in production** — deployed by zip or copy, never versioned — under Git/GitHub without leaking secrets, databases or user files. Two steps: `preparar` shows exactly what would be committed (with a masked secret scan and a size check), `enviar` commits, tags and pushes with a per-repository deploy key. It refuses to push while a secret is detected, keeps SQL migrations but ignores dumps, re-indexes so files ignored later actually leave the commit, and warns about `.bak` folders. Fully tested end-to-end in CI. Licensed under [MIT](LICENSE).
