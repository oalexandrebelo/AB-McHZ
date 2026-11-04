<p align="center"><img src="assets/brand/ab-512.png" width="128" alt="AB-McHZ"></p>

# AB-McHZ

Controle das telas do Mac pela barra de menus: brilho do monitor por DDC, resolução e taxa com reversão automática, diagnóstico e reparo de EDID, presets e automação por monitor. Feito e medido num Mac mini M4 (macOS 27) com BenQ XL2430T e ASUS PG259QN.

**Uso pessoal e não comercial.** Licença [PolyForm Noncommercial 1.0.0](LICENSE.md): o código é aberto para ler, estudar, modificar e usar sem fins comerciais. Uso comercial precisa de autorização do autor.

## Edições

| | Livre | PRO |
|---|---|---|
| Brilho por DDC (slider no menu); contraste e outros VCP pelo `hetzctl set` | ✓ | ✓ |
| Resolução e taxa com watchdog de 6 s (só vira permanente depois de confirmada) | ✓ | ✓ |
| Diagnóstico e reparo de EDID com cabeçalho corrompido (até 3 tentativas por conexão) | ✓ | ✓ |
| `hetzctl` (leitura, modos, VCP) | ✓ | ✓ |
| Presets por monitor (`profiles/*.json`), incluindo ULMB do PG259QN a 240 Hz | | ✓ |
| Atalhos ⌃⌥⌘1–9 para os presets (sem permissão de Acessibilidade) | | ✓ |
| Automação por monitor: taxa máxima do perfil ao conectar ou acordar (PG259QN 360 → 240 Hz; XL2430T 144 Hz na DP, 60 Hz na HDMI), perfil de cor sRGB uma vez por conexão | | ✓ |
| Preset por app em primeiro plano (ex.: jogo → `competitivo`) e por horário (BenQ: `noite` das 20:00 às 07:00) | | ✓ |
| Próximos: telas virtuais (BetterDummy, MIT), proteção de layout, escurecimento por gama | | ✓ |

A automação não briga com você:
- modo escolhido à mão vale até reconectar o monitor;
- preset escolhido à mão vale até mudar o app em primeiro plano ou o horário;
- modo que não pegou não é tentado de novo;
- um sleep curto (até 5 min) não conta como reconexão.

O PRO vem com **14 dias de avaliação** a partir do primeiro uso. A licença PRO é **vitalícia** e fica **vinculada ao Mac e ao usuário de login** para o qual foi emitida: a chave guarda só um hash do UUID do Mac com o nome do usuário, sem nenhum identificador legível. Ative em **Ajustes… › Licença** ou:

```bash
hetzctl license machine                  # vínculo deste Mac/usuário, para pedir uma chave
hetzctl license activate ABMCHZ-PRO.…
```

A chave é verificada offline (assinatura Ed25519), sem conta nem internet. Como o código é aberto, a licença é um acordo, não uma trava.

## Instalar

1. Baixe o `AB-McHZ-<versão>.dmg` na [última release](https://github.com/oalexandrebelo/AB-McHZ/releases/latest).
2. Abra o DMG e arraste o **AB-McHZ** para **Aplicativos**.
3. Abra o AB-McHZ. Ele aparece na barra de menus com a taxa das telas (ex.: `60Hz`) e passa a abrir sozinho no login.

Requer macOS 14 ou mais novo num Mac com Apple Silicon (o DDC usa o `IOAVService`, que só existe no Apple Silicon).

**Primeira abertura.** Enquanto as releases não forem assinadas com Developer ID (conta Apple Developer), o macOS bloqueia a primeira abertura de app baixado da internet. Abra uma vez, clique em **OK** e vá em **Ajustes do Sistema › Privacidade e Segurança › Abrir Mesmo Assim**. Só na primeira vez.

**No app:**
- **Ajustes…** (⌘,, ou abrir o app de novo): abrir no login, reparo de EDID, automação, licença, linha de comando, pasta de perfis, atualizações.
- **Linha de comando:** o `hetzctl` vem dentro do app. Em Ajustes › Linha de comando, **Instalar hetzctl** cria o link `/usr/local/bin/hetzctl` (pede a senha de administrador).
- **Perfis:** os do BenQ XL2430T e dos ASUS PG259QN/XG259QN vêm no app. Um `.json` com o mesmo `id` em `~/Library/Application Support/AB-McHZ/profiles` substitui o do app (`hetzctl profiles` mostra o que está valendo).
- **Atualizações:** uma vez por dia o app consulta a última release do GitHub e mostra **Baixar versão X…** no menu quando há versão nova (desligável em Ajustes).

**Desinstalar:** saia pelo menu e arraste o app de Aplicativos para o Lixo. Preferências e licença ficam em `defaults` (`org.ab-mchz.AB-McHZ`, `org.ab-mchz.shared`).

**Quem instalou a 0.2 pelo `scripts/install.sh`:** na primeira abertura a versão nova remove o LaunchAgent antigo, manda `~/Applications/AB-McHZ.app` para o Lixo, troca a cópia de `~/.local/bin/hetzctl` por um link para o app e apaga perfis copiados que não foram editados.

## Compilar

Requer Xcode 16 ou mais novo (Swift 6).

```bash
swift test                                   # testes
ABMCHZ_PROFILES=$PWD/profiles swift run AB-McHZ   # app direto do código, com os perfis do repositório
scripts/package.sh                           # dist/AB-McHZ.app e dist/AB-McHZ-<versão>.dmg
```

`package.sh` assina ad hoc. Com `SIGN_IDENTITY="Developer ID Application: …"` assina com hardened runtime e, com `NOTARY_PROFILE`, notariza e grampeia o DMG.

**Release:** atualize `VERSION`, faça commit e crie a tag `v<versão>`. O workflow `release.yml` testa, gera o DMG e publica a release (assinada e notarizada se os segredos de Developer ID estiverem configurados).

## Estrutura

- `Sources/HetzCore`: motor (DDC/MCCS por `IOAVService`, EDID por I2C, modos com watchdog, perfis, licença).
- `Sources/hetzctl`: CLI.
- `Sources/ABMcHZApp`: app da barra de menus e janela de Ajustes.
- `profiles/`: perfis medidos por monitor (vão dentro do app).
- `packaging/`: `Info.plist` do app; `scripts/package.sh` monta o app e o DMG; `.github/workflows/`: CI e release.
- `docs/`: arquitetura, perfis, o que falta para o produto, oportunidades PRO (`PRO-OPORTUNIDADES.md`) e revisão de código (`REVISAO-CODIGO.md`).

## Origem e créditos

Implementação própria sobre APIs da Apple e medição direta do hardware. Nenhum código, texto ou recurso de apps comerciais de terceiros. Projetos MIT usados como referência são creditados no arquivo onde a referência aparece.
