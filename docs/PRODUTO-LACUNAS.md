# AB-McHZ — o que falta para virar produto

Data: 2026-11-03 · Referência de mercado: lista pública de recursos do BetterDisplay 5 (README de `github.com/waydabber/BetterDisplay`).

## 0. Por que não é um fork do BetterDisplay

O repositório `waydabber/BetterDisplay` tem **um único arquivo, o `README.md`**, sem código-fonte e sem licença (todos os direitos reservados, Kodeon Software). Não existe código para bifurcar. O app é distribuído só como binário comercial (Pro a US$ 21,99), e "extrair" algo dele seria engenharia reversa de software proprietário. Republicar com outra marca seria violação de direito autoral e de marca. Isso já estava registrado em `REVISAO-ARQUITETURA.md` §1.

Regra do projeto (sala limpa):
- O README do BetterDisplay serve **só como lista de recursos do mercado**. Nome de recurso não é protegido; implementação é.
- Nada de desmontar, injetar ou copiar o binário, os textos de interface, os ícones ou o nome do BetterDisplay.
- As fontes permitidas são:
  - APIs públicas da Apple;
  - headers privados já documentados pela comunidade;
  - código MIT com atribuição: BetterDummy, MonitorControl, DeskPad, m1ddc, displayplacer;
  - medição direta do hardware.

## 1. Mapa de recursos

Legenda: ✅ pronto no AB-McHZ · 🟡 parcial · ⬜ falta.

| Recurso (mercado) | AB-McHZ hoje | Caminho limpo | Prioridade |
|---|---|---|---|
| Brilho/contraste por DDC | ✅ `setVCP`, slider na barra de menus | — | — |
| Detecção de capacidades DDC | 🟡 lê VCP avulso | Ler a string de capacidades MCCS (VCP `0xF3` / Capabilities Request) e montar a UI a partir dela | P1 |
| Volume e entrada por DDC | ⬜ (só via `hetzctl set 0x62/0x60`) | VCP `0x62`, `0x8D` (mute) e `0x60` na UI | P1 |
| Teclas de brilho/volume do teclado | ⬜ | `CGEventTap` para teclas de mídia (ref. MonitorControl, MIT) | P1 |
| OSD próprio | 🟡 `BrightnessView` | Janela flutuante sem foco, estilo macOS | P1 |
| Escurecimento por software (abaixo do mínimo) | ⬜ | `CGSetDisplayTransferByTable` (gama) ou overlay | P1 |
| Grupos e sincronia de brilho | ⬜ | Mapear nits por perfil (`profiles/*.json` já tem alvo cd/m²) | P2 |
| EDID: leitura, diagnóstico e reparo | ✅ `edid`, `edid-fix`, reparo automático no app | — | — |
| EDID override completo (arquivo custom) | 🟡 só cabeçalho corrigido | Aceitar `.bin` de `profiles/edid/`, atrás de feature flag | P2 |
| Troca de resolução com watchdog | ✅ `mode`, menu de modos, confirmação | — | — |
| Proteção de layout, resolução e perfil de cor | 🟡 perfil aplica uma vez | Observar `CGDisplayRegisterReconfigurationCallback` e reaplicar o último estado válido | P1 |
| Arranjo visual das telas | ⬜ | `CGConfigureDisplayOrigin` + editor simples | P3 |
| Desconectar/reconectar sem tirar o cabo | ⬜ | `CGSConfigureDisplayEnabled` (privado, documentado) | P2 |
| Telas virtuais (headless, AnyDesk) | ⬜ | `CGVirtualDisplay` (ref. BetterDummy, MIT) | **P1** |
| HiDPI flexível | ⬜ | Tela virtual HiDPI espelhada na física | P2 |
| Modos de cor RGB/YCbCr, bpc, faixa HDMI | ⬜ | APIs privadas do DCP, atrás de flag; medir antes | P3 |
| XDR/HDR brilho extra | ⬜ | EDR, só em telas Apple XDR (ver revisão §1) | P3 |
| PIP / streaming de tela | ⬜ | ScreenCaptureKit (ref. DeskPad, MIT) | P3 |
| Filtros de imagem e LUT 3D | ⬜ | Metal sobre captura SCK; custo alto | P4 |
| HDMI-CEC | ⬜ | Pesquisar suporte no conversor HDMI do Mac (PS190) antes de prometer | P4 |
| Controle de TV por rede (webOS, Tizen) | ⬜ | APIs públicas dos fabricantes | P4 |
| Diagnóstico (banda, DSC, DPCD) | 🟡 log de EDID | Ler propriedades `IOAVService`/DCP no `hetzctl list` | P2 |
| CLI | ✅ `hetzctl` | Manter paridade com a UI | — |
| Automação (URL scheme, Atalhos) | ⬜ | `CFBundleURLTypes` + App Intents | P2 |
| Perfis por monitor | ✅ `profiles/*.json` (BenQ, ASUS) | Importar/exportar pela UI | P2 |

## 2. O que falta para ser *produto* (não recurso)

| Item | Situação | O que fazer | Prioridade |
|---|---|---|---|
| Marca e ícone | ⬜ → feito nesta rodada | Logo AB em `assets/brand/`, `AppIcon.icns` no bundle | **P0** |
| Licença | ✅ PolyForm Noncommercial 1.0.0 (`LICENSE.md`) | Uso pessoal e não comercial; uso comercial só com autorização | — |
| README público | ✅ `README.md` | Manter a tabela Livre/PRO em dia | — |
| Repositório público | ⬜ não é repositório git | `git init`, `.gitignore` (`.build/`), GitHub público. **Precisa do seu OK.** | **P0** |
| Assinatura e notarização | 🟡 ad hoc | Developer ID (conta Apple Developer, US$ 99/ano) + `notarytool` | P1 |
| Distribuição | 🟡 `scripts/install.sh` compila na máquina | DMG + cask Homebrew próprio (`tap`) | P1 |
| Abrir no login | 🟡 LaunchAgent manual | `SMAppService.mainApp.register()` (macOS 13+) com chave na UI | P1 |
| Atualização automática | ⬜ | Sparkle 2 (MIT) com appcast assinado no GitHub Releases | P1 |
| Ajustes e primeiro uso | ⬜ | Janela de Ajustes; aviso de DDC/CI ligado no OSD do monitor | P1 |
| Idiomas | 🟡 só pt-BR | String Catalog (`.xcstrings`) pt-BR + en | P2 |
| CI | ⬜ | GitHub Actions `macos-15`: `swift build` + `swift test` | P1 |
| Coleta de erros | ⬜ | Exportar log local (`OSLog`); sem telemetria por padrão | P2 |

## 3. Ordem sugerida

1. **P0 (lançável como open-source):** licença, README, ícone, repositório público, CI.
2. **P1 (motivo para instalar):**
   - telas virtuais para Mac sem monitor e AnyDesk;
   - proteção de configuração;
   - teclas de mídia e OSD;
   - volume e entrada por DDC;
   - Ajustes;
   - abrir no login;
   - Sparkle;
   - assinatura.
3. **P2:** HiDPI por espelhamento, EDID override por arquivo, desconectar tela, sincronia de brilho, Atalhos, inglês.
4. **P3/P4:** modos de cor, XDR, PIP, filtros/LUT, CEC, TVs em rede.

## 4. Edições Livre e PRO (implementado)

Modelo inspirado no mercado (base livre, recursos avançados pagos ou licenciados), com código próprio:
- `Sources/HetzCore/License.swift`: `ProFeature` lista o que é PRO. `Edition` resolve entre chave válida, avaliação de 14 dias e edição livre.
- Chave `ABMCHZ-PRO.<payload>.<assinatura>` verificada offline com Ed25519. A chave pública fica embutida no código.
- A chave privada fica só em `~/.config/ab-mchz/licenca-ed25519.key`, fora do repositório (`*.key` no `.gitignore`). **Sem ela não dá para emitir licenças: faça backup.**
- Emitir: `hetzctl license issue "<dono>"`. Ativar: `hetzctl license activate <chave>` ou pelo menu do app.
- Limite consciente: a avaliação fica em `UserDefaults` (`org.ab-mchz.shared`) e pode ser reiniciada apagando a preferência. Como o código é aberto, a trava do PRO é contrato de licença, não DRM.
- Todo recurso PRO novo entra em `ProFeature` e checa `Licensing.current.allows(...)` no app e no CLI.

## 5. Automação por monitor (PRO, implementado)

Regras em `Sources/HetzCore/AutoPilot.swift`, aplicadas pelo app:
- **Taxa:** primeira de `[hz, fallbackHz]` que o link oferece como modo seguro.
  - PG259QN: 360 Hz pela DP 1.4, 240 Hz pela HDMI 2.0.
  - XL2430T: 144 Hz pela DP, 60 Hz pela HDMI.
  - Preset com `macos.hz` (ULMB) fixa a taxa.
- **Quando corrige a taxa:** só ao conectar, ao acordar ou quando o preset muda o alvo. No timer, só observa; modo diferente do último aplicado pelo app é escolha do usuário. Modo revertido pelo watchdog não é repetido na mesma conexão.
- **Permanência:** a troca é `.forSession` durante o watchdog e vira `.permanently` só depois de confirmada.
- **Cor:** perfil ICC do perfil (`sRGB IEC61966-2.1`) uma vez por conexão.
- **Presets automáticos:** app em primeiro plano > agenda (`"schedule": "20:00-07:00"`) > padrão. São aplicados na borda: só quando o desejado muda. DDC que falha é tentado até 3 vezes.
- **Conexão:** chaveada por vendor/modelo/série do macOS; ausência de até 5 min (sleep) não é reconexão.
- **Segurança DDC:** perfis só gravam códigos de imagem e áudio (`MCCS.safeCodes`). O barramento recusa escrita fora do `0x37`, então nada grava na EEPROM do EDID.
- **CLI:** `hetzctl optimize <tela> [--dry-run] [--preset]`.
