# AB-McHZ (AppleHetZ) — Revisão de viabilidade da especificação

Data: 2026-11-03 · Base: especificação "Ultimate Open-Source Display Engine" + medições reais no Mac mini M4 (macOS 27.2).

A especificação acerta a direção (HAL de DDC assíncrona, watchdog de rollback, circuit breaker), mas várias afirmações não correspondem a como o macOS funciona. Construir sobre elas leva a código que não roda. Abaixo, o que muda.

## 1. Correções obrigatórias

| Afirmação na spec | Realidade | Ajuste |
|---|---|---|
| Daemon "user-space com privilégio root" cria `CGVirtualDisplay` | `CGVirtualDisplay` e `CGConfigureDisplayWithDisplayMode` exigem conexão com o WindowServer da sessão gráfica do usuário. Um LaunchDaemon root não tem essa sessão. | Processo principal = **LaunchAgent** na sessão Aqua do usuário. Root só se um dia houver algo que exija (hoje nada exige: DDC via `IOAVService` roda sem root). |
| Watchdog com "temporizador atômico em kernel-space (`dispatch_source_t`)" | `dispatch_source_t` é user-space (libdispatch). | Timer de 10–15 s no agente; o rollback é refazer a configuração anterior via CoreGraphics. |
| Rollback a partir de "NVRAM/SQLite" | Gravar NVRAM exige root e não é lugar de preferência de app. | Último estado válido em arquivo/SQLite no `~/Library/Application Support/AB-McHZ`. |
| RAII em C++ garante limpeza "mesmo com `SIGKILL`" | Nenhum destrutor roda em `SIGKILL`. | Não é preciso: o WindowServer destrói os `CGVirtualDisplay` quando a conexão do processo cai. O `launchd` reinicia o agente e ele recria as telas a partir do estado salvo. |
| Alocação de framebuffer "alinhada a 64 bytes" e "pixel clock customizado" no `CGVirtualDisplay` | O framebuffer é alocado pelo WindowServer/DCP; o app não controla alinhamento. `CGVirtualDisplayDescriptor` expõe tamanho, PPI/mm, refresh e modos — não pixel clock. | Remover da spec. |
| XDR/headroom de brilho em monitor externo via I2C | Brilho extra em telas XDR da Apple vem de EDR (conteúdo HDR forçando o backlight + compensação de gama). Studio Display controla brilho por USB HID, não DDC. Monitores DDC comuns não têm "headroom" escondido. | Escopo de XDR = telas Apple XDR (EDR). Em monitores DDC, brilho = VCP `0x10` dentro do range do OSD. |
| HiDPI fracionário via "EDID injetado no `IODisplayConnect`" | `IODisplayConnect` é da pilha Intel/IOFramebuffer. No Apple Silicon o caminho comprovado é **espelhar um `CGVirtualDisplay` HiDPI** na tela física (o que BetterDummy, de código MIT, fazia). EDID custom volátil existe no Apple Silicon via APIs privadas do DCP. | HiDPI = tela virtual + espelhamento. EDID override = fase posterior, atrás de feature flag. |
| Engenharia reversa do BetterDisplay (binário comercial) para extrair "ouro" | Copiar implementação de binário proprietário contamina a licença do projeto open-source. `ipatool` não serve: baixa apps iOS cifrados com FairPlay, não apps macOS. | Fontes limpas: headers privados já documentados pela comunidade, BetterDummy e MonitorControl (MIT), DeskPad (MIT), e medição direta do hardware (como abaixo). |
| Concorrência "lock-free" com Actors | Actors serializam por fila; não são lock-free, mas eliminam data races. | Actors para estado; `Atomic` (Swift Synchronization) só onde medido como gargalo. |
| Sync P2P com CRDT + mDNS + Noise | Viável, mas é um produto à parte. | Fase 4. Até lá, perfis em JSON versionado (ver `profiles/`). |

## 2. O que a medição real mostrou (Mac mini M4, 2026-11-03)

- A BenQ XL2430T está ligada na **HDMI 2** e o macOS **não tem o EDID** dela (vendor/product `0`, 720p50, "projector"). O EDID lê por I2C (`IOAVService`), mas está **corrompido**: byte 0 = `0xFF` em vez de `0x00` (cabeçalho inválido, checksum do bloco 0 = 255). Com o byte 0 corrigido o checksum fecha em 0: é exatamente um byte errado na EEPROM da entrada HDMI 2. Uma leitura que dá a volta no endereço (feita pelo `hetzctl`) confirma que o `0xFF` está mesmo gravado, não é artefato de offset.
- Sem EDID, o macOS só marca o modo atual como seguro (`kDisplayModeSafeFlag` = `0x2`; os demais vêm com `0x9`). `CGCompleteDisplayConfiguration` devolve sucesso e **ignora** a troca. O BetterDisplay não é a trava: com ele fechado o resultado é o mesmo.
- O EDID HDMI dessa unidade limita a **170 MHz de pixel clock → 1080p @ 60 Hz no máximo**. 144 Hz só pela DisplayPort.
- DDC/CI responde normalmente (brilho, contraste, ganhos RGB, entrada, firmware `0x0201`).
- **Causa raiz: EEPROM de EDID corrompida na entrada HDMI 2 da BenQ.** O macOS valida cabeçalho e checksum, descarta o EDID e o `AppleDisplayManager` fica com "null info" e **zero recursos alocados**, recusando qualquer modo. Os erros no replug do conversor PS190 da HDMI do Mac mini (`AppleDCPPS190`: `FRL error count`, `Requested DSC bpp not supported`, `dptx-phy … Failed to read EDID with ret=0xe00002c2`) são **consequência**: sem EDID válido o conversor não sabe que o monitor é HDMI 1.4. Desligar no botão não gera hotplug (o HPD da BenQ é alimentado pelos 5 V do Mac).
- Correções possíveis, da mais simples à mais invasiva:
  1. outra entrada do monitor (HDMI 1 ou DisplayPort normalmente têm EEPROM própria; não verificado);
  2. EDID override no AB-McHZ com o byte 0 corrigido;
  3. regravar o byte 0 da EEPROM via I2C `0x50`. É reparo de hardware: só com consentimento explícito, backup em `profiles/edid/`, e pode falhar se a EEPROM tiver proteção de escrita.

Consequências diretas para o motor:

1. **Detector de "EDID ausente"**: se `CGDisplayVendorNumber == 0`, ler o EDID por I2C (`0x50`), validar cabeçalho e checksum e apontar o byte corrompido. Também oferecer o caminho de correção: outra entrada, override ou reparo.
2. **Nunca escrever em `0x50`** fora de um reparo explícito. Escrita de DDC vai só para `0x37`, e um endereço errado é exatamente o tipo de bug que corrompe EEPROM de EDID.
3. **Toda troca de modo verifica o resultado** (`CGDisplayCopyDisplayMode` após aplicar). Sucesso do `CGError` não é prova.
4. **Watchdog de rollback**: já prototipado no probe usado hoje — aplica, observa 6 s (display online + modo efetivo) e reverte sozinho.

## 3. Ordem de construção recomendada

1. `HetzCore`: DDC HAL (`IOAVService` Apple Silicon / `IOI2CInterface` Intel), MCCS, backoff com jitter, circuit breaker (3 timeouts → 30 s de isolamento), leitura de EDID por I2C. CLI `hetzctl`.
2. Perfis: aplicar `profiles/*.json` via DDC + CoreGraphics com watchdog.
3. Telas virtuais/HiDPI por espelhamento.
4. Modos de conexão (RGB/YCbCr, bpc) e EDID override — APIs privadas, atrás de flag.
5. UI de menu bar; sync entre máquinas.
