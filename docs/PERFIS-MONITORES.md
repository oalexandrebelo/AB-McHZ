# Perfis autorais AB-McHZ — guia de aplicação

Os perfis completos (com origem de cada valor) estão em `profiles/*.json`, no formato que o AB-McHZ vai aplicar sozinho. Até lá, este é o passo a passo manual.

**Regra de ouro:** brilho é o único valor "estimado" (alvo ~120 cd/m² em sala iluminada). Todo o resto vem de manual oficial, relatório de fábrica ou medição feita nesta máquina.

---

## Mac mini M4 — BenQ XL2430T

### 1. Cabo e porta (o que mais importa)
Hoje: **HDMI 2 → máximo 1080p @ 60 Hz** (limite do EDID HDMI desta unidade: 170 MHz).
Recomendado: **USB-C (Thunderbolt) → DisplayPort**, direto, sem hub → **1920×1080 @ 144 Hz**.

### 2. macOS
- Resolução **1920×1080**, sem HiDPI. Taxa **144 Hz** na DP (60 Hz se ficar na HDMI).
- Perfil de cor: **sRGB IEC61966-2.1**.
- Depois de religar, conferir que a tela aparece como "BenQ XL2430T" e não como "Display" genérico.

### 3. OSD (uma vez)
| Menu | Valor |
|---|---|
| System > Other Setting > DDC/CI | ON |
| System > Other Setting > Auto Power Off | OFF |
| System > Other Setting > Input Auto Switch | OFF |
| System > Other Setting > Resolution Notice | OFF |
| Display > Display Mode | Full |
| Display > HDMI RGB PC Range | RGB (0 ~ 255) |

### 4. Presets (salvar nos botões do S Switch)
| Ajuste | Trabalho → Gamer 3 | Competitivo → Gamer 1 | Noite → Gamer 2 |
|---|---|---|---|
| Brightness | 25 | 55 | 8 |
| Contrast | 50 | 50 | 50 |
| Sharpness | 5 | 5 | 5 |
| Gamma | 3 (≈2.2) | 3 | 3 |
| Color Temperature | User Define R93 G88 B97 | igual | igual |
| AMA | High | High | High |
| Black eQualizer | 0 | 12 | 0 |
| Color Vibrance | 10 | 12 | 10 |
| Low Blue Light | 0 | 0 | 0 (usar Night Shift) |
| Blur Reduction | OFF | OFF (ON só a 144 Hz) | OFF |
| Instant Mode | ON | ON | ON |

Os ganhos **R93 G88 B97** já estavam no monitor (lidos por DDC). São uma calibração deliberada desta unidade e foram preservados.

Para salvar: ajuste tudo → **Game Settings > Save Settings > Gamer N** (ou segure o botão Gamer N do S Switch por 5 s).

---

## MacBook Pro M5 Pro — ASUS ROG Swift PG259QN

**Referência de cor da mesa.** O relatório de fábrica mede **ΔE 0,49** e gama 2.2 no modo padrão via DisplayPort. Mexer em cor só piora.

### 1. Cabo e porta
**USB-C → DisplayPort 1.4 (HBR3)** → **1920×1080 @ 360 Hz, 8 bpc**. HDMI 2.0 trava em 240 Hz.

### 2. macOS
- Resolução **1920×1080**, sem HiDPI, **360 Hz**. Se aparecer "Variável", testar; senão, 360 Hz fixo (módulo G-SYNC sem suporte Mac confirmado).
- Perfil de cor: **sRGB IEC61966-2.1**. HDR: **desligado**.

### 3. OSD (uma vez)
| Menu | Valor |
|---|---|
| System Setup > DisplayPort Deep Sleep | OFF |
| System Setup > Auto SDR Brightness | OFF |
| Image > Variable Backlight | OFF |
| Input Select > Input Auto Switch | OFF |
| Color > DP SDR YCbCr sRGB Gamma | ON |

### 4. Presets
| Ajuste | Trabalho | Competitivo | ULMB (opcional) |
|---|---|---|---|
| GameVisual | de fábrica (não trocar) | de fábrica | de fábrica |
| Brightness | 30 | 60 | 100 |
| Contrast / Color Temp. / Gamma / Saturation | de fábrica (50 / — / 2.2 / —) | idem | idem |
| OD | Normal | Normal | indisponível |
| Dark Boost | OFF | nível mais baixo | OFF |
| ULMB | OFF | OFF | ON, 240 Hz fixo |

---

## MacBook Pro M5 Pro — ASUS ROG Strix XG259QN

### 1. Cabo e porta
**USB-C (outra porta) → DisplayPort 1.4** → **1920×1080 @ 360 Hz**. Não usar o overclock de 380 Hz.

### 2. macOS
- Resolução **1920×1080**, sem HiDPI, taxa **Variável** (Adaptive-Sync certificado).
- Perfil de cor: **sRGB IEC61966-2.1**. HDR: **desligado**.

### 3. OSD (uma vez)
| Menu | Valor |
|---|---|
| System Setup > OSD Setup > DDC/CI | ON |
| System Setup > DisplayPort Stream | DisplayPort 1.4 |
| Gaming > Overclocking | OFF |
| Gaming > Variable Refresh Rate | ON |
| Input Select > Auto Input Detection | OFF |
| Image > ASCR | OFF |

### 4. Presets
| Ajuste | Trabalho | Competitivo (MyFavorite slot 1) |
|---|---|---|
| GameVisual | sRGB | FPS |
| Brightness | 25 → igualar ao PG259QN | 60 |
| Gamma | travado no sRGB | 2.2 |
| Variable OD | padrão (10); −2 se houver halo claro | padrão |
| Shadow Boost | OFF | nível 1 |
| VividPixel | mínimo | mínimo |
| ELMB SYNC | OFF | OFF (opcional ON) |

**Casar os dois ASUS:** janela branca atravessando os dois monitores → ajuste o brilho do XG259QN até igualar o PG259QN. Se o vermelho do XG259QN continuar visivelmente mais saturado no modo sRGB, troque para **Racing + Color Temp. Normal + Gamma 2.2 + Saturation 50**.
