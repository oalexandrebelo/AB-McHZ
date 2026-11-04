# Revisão de código — 2026-11-03

Escopo: `Sources/`, `Tests/`, `scripts/`, README e docs no commit `e1194ed`.
- `swift build` ok; `swift test` com 58/58.
- Nenhum caminho grava na EEPROM de EDID (I2C `0x50`): as escritas vão só para `0x37` (DDC). O reparo de EDID usa o DCP (`SetVirtualEDIDMode`).

## Situação (2026-11-03, commit seguinte a `d5d4244`)

Itens 1 a 8 e 10 a 12 corrigidos. A lógica foi para `HetzCore/AutoPilot.swift`, com testes em `AutoPilotTests.swift`. O item 9 foi corrigido em parte: o relógio só avança e um início no futuro conta como expirado. O PRO segue sem trava técnica, por ser código aberto. Item 7 completo na 0.3.0: toda transação I2C pega uma trava de arquivo (`flock`) compartilhada entre o app e o `hetzctl`. Item 12 deixou de existir: o `install.sh` foi substituído pelo DMG (`scripts/package.sh`).

## Achados originais

| # | Gravidade | Problema | Onde | Correção |
|---|---|---|---|---|
| 1 | Alta | A otimização tenta de novo, a cada 60 s, um modo que o watchdog reverteu: tela preta a cada minuto se o cabo não sustenta 360 Hz | `App.swift` `optimizeDisplays`, `Optimizer.swift` | Guardar (tela, modo) que falhou na conexão; corrigir taxa só ao conectar/acordar, não no timer |
| 2 | Alta | Briga com o usuário: desfaz modo escolhido nos Ajustes do Sistema ou no `hetzctl`, desfaz o preset `ulmb` (240 Hz → 360 Hz) e reaplica o perfil de cor a cada minuto | `App.swift`, `Optimizer.swift` | Tratar como escolha do usuário todo modo diferente do último aplicado pelo app; `presetClicked` marca a tela como `manualMode`; cor uma vez por conexão |
| 3 | Alta | Troca de modo gravada como `.permanently` antes do watchdog: crash, sleep ou Ctrl-C no meio deixa um modo possivelmente sem imagem salvo | `Displays.swift` `DisplayModes.apply` | Aplicar `.forSession`, tornar permanente só após o watchdog (e confirmação na 1ª vez de cada modo) |
| 4 | Média-alta | "Uma vez por conexão" vira "a cada sumiço": depois do sleep o preset padrão volta (brilho 25/30) e marca como feito mesmo se o DDC falhou | `App.swift` | Identificar conexão pelo EDID com carência de alguns minutos; podar depois do guard; marcar só com DDC ok |
| 5 | Média | Reparo de EDID repete para sempre (link pisca a cada minuto quando não pega) e ignora `busy` | `App.swift` `repairMissingEDIDs` | Backoff/limite por conexão; pular com `busy`; não repetir `SetVirtualEDID` no `withRetry` |
| 6 | Média | DDC sem lista permitida: perfil pode gravar `0x04` (reset de fábrica), `0xD6` (energia), `0x60` (entrada) | `Profile.swift`, `Optimizer.swift`, `hetzctl set` | Permitir só códigos de imagem em perfis e caminhos automáticos; `--force` no CLI para os demais |
| 7 | Média | Sem trava de instância única nem de I2C entre processos (app + `hetzctl`, ou dois apps) | `DDC.swift`, `App.swift` | `NSRunningApplication` no início; `flock` por transação DDC |
| 8 | Média | Chave de licença com quebra de linha (e-mail) é recusada; ativar não atualiza o app na hora | `License.swift`, `App.swift` | Remover todo espaço em branco; `refresh()` após ativar |
| 9 | Baixa-média | Voltar o relógio reinicia a avaliação. A licença PolyForm NC permite modificar o código, e o `LICENSE.md` não tem termos do PRO | `License.swift`, `LICENSE.md` | Data "vista por último" só avança. Termos do PRO num `EULA-PRO.md`, sabendo que no código aberto isso é acordo, não trava |
| 10 | Baixa | Preset automático ignora `requires`/`hzOverride`; vários `default` escolhem um arbitrário | `Optimizer.swift`, `Profile.swift` | Validar um único `default` ao carregar |
| 11 | Baixa | Reentrância menor: `manualMode` marcado mesmo com clique ignorado; meio-aberto do circuit breaker recusa chamada concorrente | `App.swift`, `Resilience.swift` | Ajustes pontuais |
| 12 | Baixa | `install.sh`: `bootstrap` logo após `bootout` pode falhar; não instala o `hetzctl`; sobrescreve perfis editados; falta `CFBundleVersion` | `scripts/install.sh` | Esperar o `bootout`; instalar `hetzctl`; `cp -n`; `CFBundleVersion` |

## O que os docs prometem a mais

- README "brilho e contraste por DDC": o app só tem slider de brilho; contraste só via `hetzctl set 0x12`.
- "Ao conectar ou acordar": hoje roda também a cada 60 s e a cada reconfiguração (item 1).
- "Uma vez por conexão" e "até reconectar": o sleep conta como reconexão (item 4).
- "Só modo seguro": seguro para o macOS não garante imagem no monitor (item 3).

## Testes que faltam

- A lógica do app (`busy`, conexão, `manualMode`) está presa no `AppDelegate`: extrair para um tipo testável.
- `switchMode`/`optimize` sem fake de `DisplayModes`; `repairEDID` sem teste com `FakeBus`.
- Teste de uma chave real contra a chave pública embutida, e de relógio voltando.
