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

O PRO vem com **14 dias de avaliação** a partir do primeiro uso. Depois disso, ative com uma chave de licença:

```bash
hetzctl license activate ABMCHZ-PRO.…
hetzctl optimize benq --dry-run   # mostra o que a otimização faria
```

ou pelo menu **Ativar AB-McHZ PRO…**. A chave é verificada offline (assinatura Ed25519), sem conta nem internet.

## Instalar

Requer macOS 14+ e Xcode 16+ (Swift 6).

```bash
scripts/install.sh
```

Compila, instala `~/Applications/AB-McHZ.app` com o ícone AB (aberto no login por um LaunchAgent) e o `hetzctl` em `~/.local/bin`. Perfis já instalados não são sobrescritos. Para remover: `scripts/uninstall.sh`.

CLI:

```bash
swift build -c release && .build/release/hetzctl list
```

## Estrutura

- `Sources/HetzCore`: motor (DDC/MCCS por `IOAVService`, EDID por I2C, modos com watchdog, perfis, licença).
- `Sources/hetzctl`: CLI.
- `Sources/ABMcHZApp`: app da barra de menus.
- `profiles/`: perfis medidos por monitor.
- `docs/`: arquitetura, perfis, o que falta para o produto, oportunidades PRO (`PRO-OPORTUNIDADES.md`) e revisão de código (`REVISAO-CODIGO.md`).

## Origem e créditos

Implementação própria sobre APIs da Apple e medição direta do hardware. Nenhum código, texto ou recurso de apps comerciais de terceiros. Projetos MIT usados como referência são creditados no arquivo onde a referência aparece.
