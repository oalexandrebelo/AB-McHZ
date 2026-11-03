# AB-McHZ PRO — oportunidades e fontes open-source

Data: 2026-11-03. As licenças foram conferidas na API do GitHub nesta data.

## 1. Regra de licença (decide o que pode entrar)

O AB-McHZ é **PolyForm Noncommercial 1.0.0**.

| Licença da fonte | Pode entrar no AB-McHZ? | Como |
|---|---|---|
| MIT, BSD | **Sim** | Manter o aviso de copyright no arquivo copiado e listar em `THIRD_PARTY_NOTICES.md` |
| Apache-2.0 | **Sim** | Igual, mais o `NOTICE` (se houver) e uma nota de "modificado" nos arquivos alterados |
| MPL-2.0 | Só como arquivo isolado, mantido MPL | Evitar: complica a distribuição |
| GPL-2.0/3.0 | **Não** | A GPL exige distribuir tudo sob GPL e proíbe acrescentar a restrição "não comercial". Só serve como leitura de referência; reimplementar sem copiar |
| Sem licença | **Não** | Todos os direitos reservados |

Regras de distribuição:
- Dependência por Swift Package (KeyboardShortcuts, Sparkle) é preferível a copiar arquivo.
- Código copiado vai para `Sources/ThirdParty/<projeto>/`, com o cabeçalho de licença original.

## 2. Fontes reutilizáveis

| Projeto | Licença | ★ | Último push | O que tem de útil |
|---|---|---|---|---|
| **BetterDummy** (`waydabber/BetterDisplay`, branch `opensource`, fev/2022) | **MIT** (Istvan T.) | — | 2022-02 | Telas virtuais com `CGVirtualDisplay` (headers privados no `Bridging-Header.h`), HiDPI por espelhamento (`DummyManager.swift`, `Dummy.swift`, `DisplayManager.swift`). É o ancestral open-source do BetterDisplay; **só esta versão antiga é MIT**, o app atual é fechado. |
| **MonitorControl** | MIT | 34,6k | 2026-10 | DDC Apple Silicon e Intel (`Arm64DDC.swift`, `IntelDDC.swift`), teclas de mídia (`MediaKeyTapManager.swift`), OSD nativo do macOS (`OSDUtils.swift`), atalhos |
| **Lunar** | MIT (o que está aberto) | 5,7k | 2026-10 | Controle por gama/software (`GammaControl.swift`), DDC, tela de agendamento (`Schedule.swift`), modo adaptativo. **Os modos PRO do Lunar (Sync, Location, Clock, Sensor) estão cifrados no repositório (`.swift.secret`): não são reutilizáveis.** |
| **DeskPad** | MIT | 7,9k | 2026-02 | Tela virtual exibida numa janela, útil para compartilhar ou acessar remotamente |
| **FluffyDisplay** (`tml1024`) | Apache-2.0 | 338 | — | Criação e remoção de telas virtuais, com código pequeno e legível |
| **KhaosT/CGVirtualDisplay** | Apache-2.0 | 40 | — | Headers e exemplo mínimo de `CGVirtualDisplay` |
| **m1ddc** | MIT | 757 | 2026-10 | DDC em C pelo `IOAVService`, com troca de entrada (VCP `0x60`) e volume |
| **displayplacer** | MIT | 4,5k | 2024-06 | Arranjo de telas, rotação e modo por ID (base da proteção de layout) |
| **KeyboardShortcuts** (sindresorhus) | MIT | 2,7k | 2026-09 | Atalhos globais configuráveis, via Swift Package |
| **Sparkle** | MIT (+ avisos de terceiros) | 9,9k | 2026-11 | Atualização automática assinada (EdDSA), via Swift Package |

**Não usar** (GPL-3.0):
- `kfix/ddcctl`;
- `niklasr22/BrightIntosh` (brilho extra em telas XDR);
- `lwouis/alt-tab-macos`.

`xzhih/one-key-hidpi` não tem licença, então também fica de fora. Esses projetos servem só para entender a técnica, sem copiar código.

## 3. Oportunidades PRO, por valor para as suas duas mesas

Mesas consideradas:
- **Mac mini M4 + BenQ XL2430T (HDMI), acessado pelo AnyDesk;**
- **MacBook Pro M5 Pro + ASUS ROG PG259QN 360 Hz.**

| # | Recurso PRO | Para quê | Fonte | Esforço | Risco |
|---|---|---|---|---|---|
| 1 | **Presets por app** | Abriu jogo → preset `competitivo` + 360 Hz no PG259QN; voltou ao trabalho → `trabalho`. É o que um painel de 360 Hz pede. | Própria: `NSWorkspace.didActivateApplicationNotification` + motor de presets que já existe | Baixo | Baixo |
| 2 | **Agenda de presets** (horário ou pôr/nascer do sol) | BenQ: `trabalho` de dia, `noite` (brilho 8) à noite, como o perfil já sugere | Própria. Algoritmo solar NOAA (domínio público); a tela `Schedule.swift` do Lunar (MIT) como referência de UI | Baixo | Baixo |
| 3 | **Tela virtual headless para AnyDesk** | Mac mini sem monitor ou com o BenQ desligado: tela 1080p/1440p HiDPI | BetterDummy (MIT), FluffyDisplay (Apache-2.0) | Médio | **Médio:** a tela virtual do BetterDisplay disputou recursos de vídeo com o HDMI neste Mac mini. Fica opcional e só sobe quando não há tela física. |
| 4 | **Proteção de configuração** | Reaplica arranjo, modo, taxa e perfil de cor quando o macOS bagunça (sleep, troca de cabo) | Otimizador atual + `displayplacer` (MIT) para arranjo | Baixo/médio | Baixo |
| 5 | **Escurecimento abaixo do mínimo** | Noite no BenQ abaixo do brilho 0 do hardware; PG259QN se o módulo G-SYNC não responder ao DDC | `GammaControl.swift` do Lunar (MIT) | Médio | Baixo |
| 6 | **ULMB/strobe assistido no PG259QN** | O preset `ulmb` exige 240 Hz fixo; o app troca a taxa, guia o OSD e volta a 360 Hz ao sair | Própria (o perfil já tem `requires` e `hz` 240) | Baixo | Baixo |
| 7 | **Atalhos personalizados** para presets e brilho | Trocar de preset sem abrir o menu | KeyboardShortcuts (MIT, SPM) | Baixo | Baixo |
| 8 | **Sincronia de brilho em nits** | Duas telas no mesmo Mac com a mesma luminância (350 vs 400 cd/m²) | Própria; os perfis já têm nits do painel. O sync do Lunar é cifrado. | Médio | Baixo; pouco valor hoje, porque cada monitor está num Mac |
| 9 | **Brilho XDR extra no MacBook Pro** | Tela interna acima de 500 nits | Própria (EDR por overlay Metal). BrightIntosh é GPL: não copiar. | Alto | Médio |

**Recursos livres que aumentam a adoção** (BetterDisplay e MonitorControl também os dão de graça):
- teclas de mídia com OSD nativo (MonitorControl, MIT);
- volume e troca de entrada por DDC (m1ddc, MIT).

## 4. Produto (distribuição)

- **Atualização:** Sparkle 2 (MIT) com appcast no GitHub Releases, assinatura EdDSA.
- **Abrir no login:** `SMAppService.mainApp` (nativo), no lugar do LaunchAgent do `install.sh`.
- **Créditos:** `THIRD_PARTY_NOTICES.md` com o aviso de cada fonte MIT/Apache usada.
- **Assinatura:** Developer ID e notarização (conta Apple Developer) para rodar sem o aviso do Gatekeeper em outros Macs.

## 5. Situação

Feitos em 2026-11-03:
- **1.** preset por app;
- **2.** agenda (BenQ `noite`, 20:00–07:00);
- **6.** ULMB com taxa de 240 Hz fixada pelo preset;
- **7.** atalhos ⌃⌥⌘1–9, pelo Carbon `RegisterEventHotKey`, sem dependência nova nem permissão de Acessibilidade.

Próximos: 4 (proteção de layout), 3 (tela virtual a partir do BetterDummy MIT) e `THIRD_PARTY_NOTICES.md` quando o primeiro código de terceiros entrar.

## 6. Ordem sugerida (original)

1. Itens 1, 2, 6 e 7. Usam só o que já existe e entregam valor imediato nos dois monitores.
2. Item 4 e `THIRD_PARTY_NOTICES.md`.
3. Item 3, a tela virtual a partir do BetterDummy MIT, opcional e testada no Mac mini com o BenQ ligado e desligado.
4. Itens 5, 8 e 9.
