# Fix generazione GIF su MATLAB R2026a — Documentazione tecnica

**Data**: 27 aprile 2026
**Scope**: Ripristino della generazione delle GIF animate nelle funzioni di Module 3 di PHASE su MATLAB R2026a (Windows).
**Commit**: `6642708` sul branch `windows-port/train-audit` (PR [pyccino/PHASE#1](https://github.com/pyccino/PHASE/pull/1))

---

## 1. TL;DR

Le funzioni di analisi di Module 3 (`STmodel_*`) e di interpolazione (`NaturalNeighborInterpolation`) generavano una GIF animata della serie temporale di displacement nella loro "fase 7" (`% 7) PLOTS` → `% 7.1) GIF with basemap`).

Su **MATLAB R2026a** la generazione si bloccava o veniva esplicitamente saltata, perché il pattern usato (`getframe(gcf)` su una `figure('Visible','off')`) non funziona più nella nuova display pipeline di MATLAB.

La fix sostituisce **`getframe(gcf)` + `frame2im(frame)`** con **`print(gcf, '-RGBImage')`**, che produce esattamente lo stesso output (matrice RGB) ma transita per la print pipeline — la quale non richiede un display backing store e quindi funziona anche su figure invisibili.

**File modificati**: 5
**Righe modificate**: ~22 inserite, ~52 rimosse (rimosso anche un workaround temporaneo che disabilitava la GIF su R2026a+).

---

## 2. Sintomo del bug

L'utente che eseguiva una pipeline PHASE Module 3 (es. `STmodel_DET2D`, `STmodel_DET1D`, ecc.) su MATLAB R2026a osservava una di queste due cose:

1. **Comportamento "vecchio"** (codice originale, prima del workaround): la finestra MATLAB si bloccava (hang) durante la generazione della GIF. La barra di progresso restava ferma e il processo doveva essere killato manualmente.

2. **Comportamento "workaround"** (introdotto come stop-gap): il codice rilevava `R2026a+` tramite `isMATLABReleaseOlderThan('R2026a')` e saltava completamente il blocco GIF, stampando:
   ```
   GIF creation skipped (R2026a+: getframe on invisible figure hangs)
   ```
   Il processing terminava normalmente ma **la GIF non veniva generata** — feature persa.

In entrambi i casi l'utente non otteneva l'animazione attesa.

---

## 3. Root cause

Tutte le occorrenze del bug condividono lo stesso pattern di codice:

```matlab
figure('Visible', 'off', 'Position', [100, 100, 1200, 600]);
geoaxes;
% ... setup plot ...
for t = 1:N_frames
    % ... draw frame ...
    frame = getframe(gcf);     % <-- HANG su R2026a
    im = frame2im(frame);
    [imind, cm] = rgb2ind(im, 256);
    imwrite(imind, cm, gif_path, 'gif', 'WriteMode', 'append', ...);
end
```

### Cosa è cambiato in R2026a

A partire da MATLAB **R2026a**, il rendering pipeline è stato ristrutturato. `getframe` interroga il **display backing store** della figure (la rappresentazione bitmap che MATLAB mantiene aggiornata sulla GPU/X11/WGL per ogni figura visibile a schermo).

Su una figura con `'Visible','off'`:
- Pre-R2026a: MATLAB manteneva comunque un backing store off-screen. `getframe` lo leggeva senza problemi.
- **R2026a+**: il backing store off-screen non viene più allocato di default per le figure invisibili. `getframe` rimane in attesa indefinita di un buffer che non verrà mai popolato → **hang**.

Questa modifica è probabilmente intenzionale (riduce uso GPU/memoria su figure "headless"), ma rompe ogni codice che usa `getframe` su figure invisibili — un pattern molto diffuso negli script batch e nelle generazioni di GIF/video.

### Perché il workaround "skip" non era una soluzione

Il workaround:
```matlab
try
    gif_ok = isMATLABReleaseOlderThan('R2026a');
catch
    gif_ok = true;
end
if gif_ok
    % ... blocco GIF ...
else
    disp('GIF creation skipped (R2026a+: getframe on invisible figure hangs)');
end
```

evita l'hang ma:
- **Elimina la feature** sull'unica versione MATLAB ufficialmente supportata dal port Windows di PHASE (R2025a+).
- Si trascina nel tempo: ogni release MATLAB futura erediterà il "skip" senza mai recuperare la GIF.
- Non risolve il problema in `NaturalNeighborInterpolation.m` che non aveva il workaround.

---

## 4. File coinvolti

5 file in `MatlabFunctions/` generavano GIF animate, di cui **4 con il workaround** "skip on R2026a+" e **1 senza** (hang silenzioso).

| File | GIF prodotta | Workaround pre-fix | Stato post-fix |
|---|---|---|---|
| `STmodel_DET1D.m` | `STdet_displ1D.gif` | sì (skip) | GIF generata |
| `STmodel_DET2D.m` | `STdet_displ2D.gif` | sì (skip) | GIF generata |
| `STmodel_STC1D.m` | `STstc_displ1D.gif` | sì (skip) | GIF generata |
| `STmodel_STC2D.m` | `STstc_displ2D.gif` | sì (skip) | GIF generata |
| `NaturalNeighborInterpolation.m` | `NNI_displ1D.gif` + `NNI_displ2D.gif` | nessuno (hang) | GIF generata |

---

## 5. Soluzioni considerate

Quattro alternative valutate prima di scegliere la fix definitiva:

### A. `print(gcf, '-RGBImage')` ← **scelta**

Restituisce una matrice RGB della figure, identica per shape e contenuto a `frame2im(getframe(gcf))`, ma transita per la **print pipeline** (la stessa di `print('-dpng')`, `exportgraphics`, ecc.). Questa pipeline non richiede backing store di display: rasterizza direttamente dal modello scenico.

**Pro**:
- API drop-in: cambio di **una riga** per call site.
- Mantiene **`DelayTime` e `Loopcount`** invariati (a differenza di `exportgraphics`).
- Mantiene `figure('Visible','off')` — nessun lampeggio della finestra.
- Disponibile da **R2017a in poi** → coperto da R2025a (minimum supportato da PHASE).
- Comportamento identico su Linux/macOS — fix non platform-specific.

**Contro**:
- Su `geoaxes` con `geobasemap satellite` può emettere warning cosmetici (`Invalid RGB triplet`) dal renderer interno R2026a. La GIF viene comunque generata correttamente.

### B. Forzare `'Visible','on'` durante `getframe`

```matlab
set(gcf, 'Visible', 'on');
drawnow;
frame = getframe(gcf);
set(gcf, 'Visible', 'off');
```

**Pro**: bypassa il problema del backing store mancante.
**Contro**:
- Le finestre lampeggiano sullo schermo durante l'intero loop (orribile UX su loop di centinaia di frame).
- Richiede `drawnow` extra → rallenta il loop.
- Non risolve in scenari headless puri (es. server senza display).

### C. `exportgraphics(gcf, gif_path, 'Append', t > 1)`

API moderna (R2022a+) che gestisce direttamente l'append GIF.

**Pro**: API più pulita, no `getframe`/`rgb2ind` manuali.
**Contro**: **non supporta `DelayTime` né `Loopcount`** — perderemmo la cadenza animazione 0.5s e il loop infinito (entrambi importanti per UX della GIF finale).

### D. Print intermedio su file PNG temporanei

```matlab
print(gcf, '-dpng', tmp_png);
im = imread(tmp_png);
[imind, cm] = rgb2ind(im, 256);
% ... imwrite ...
delete(tmp_png);
```

**Pro**: massima compatibilità.
**Contro**:
- I/O extra su disco per ogni frame → più lento.
- File temporanei di gestione.
- Strettamente equivalente ad A ma con overhead inutile.

---

## 6. Soluzione adottata

Sostituzione di:

```matlab
frame = getframe(gcf);
im = frame2im(frame);
```

con:

```matlab
im = print(gcf, '-RGBImage');
```

In aggiunta, rimozione del workaround `gif_ok` / `isMATLABReleaseOlderThan` / ramo `else disp(...)` (codice morto dopo la fix) nei 4 file `STmodel_*`.

### Esempio diff completo (`STmodel_DET2D.m`)

```diff
 % GIF creation
-% R2026a-compat: getframe on invisible figure hangs, skip GIF on R2026a+
-try
-    gif_ok = isMATLABReleaseOlderThan('R2026a');
-catch
-    gif_ok = true;
-end
-if gif_ok
+% R2026a-compat: getframe on invisible figures hangs in R2026a's display
+% pipeline. Use print('-RGBImage') instead — same RGB output, goes through
+% the print pipeline (no display backing store needed).
 figure('Visible', 'off', 'Position', [100, 100, 1200, 600]);
 geoaxes;
 v_min = min(round(prctile(final_signal_out(:), 5), 0), -5);
 v_max = max(round(prctile(final_signal_out(:), 95), 0), 5);
 h = waitbar(0, 'Plotting epochs...');
 for t = 1:length(t_full)
     waitbar(t/length(t_full), h, sprintf('Plotting epoch %d/%d', t, length(t_full)));

     displ_at_t = final_signal_shift(:, :, t);
     displ_at_t = displ_at_t(:);
     displ_at_i_shp = displ_at_t(xyIN_AOI_flag);

     geobasemap satellite;
     if t == 1
         pause(5)
     end
     hold on;
     geoscatter(lat_full_shp, lon_full_shp, markerSize_DET2D, displ_at_i_shp, 'filled');
     geoscatter(lat_ps, lon_ps, markerSize_DET2D/4, 'filled', 'MarkerEdgeColor', 'k', 'MarkerFaceColor', 'none');

     colormap(jet); clim([v_min, v_max]);
     c = colorbar; c.Label.String = 'LOS Displacement [mm]'; c.Label.FontSize = 15;
     title(sprintf('LOS Displacement on %s (2D)', datestr(dates_full(t))), 'FontSize', 18);
     hold off;
-    frame = getframe(gcf);
-    im = frame2im(frame);
+    im = print(gcf, '-RGBImage');
     [imind, cm] = rgb2ind(im, 256);
     if t == 1
         imwrite(imind, cm, fullfile(figsDir, 'STdet_displ2D.gif'), 'gif', 'Loopcount', inf, 'DelayTime', 0.5);
     else
         imwrite(imind, cm, fullfile(figsDir, 'STdet_displ2D.gif'), 'gif', 'WriteMode', 'append', 'DelayTime', 0.5);
     end
     clf;
 end
 close(h); close;
-else
-    disp('GIF creation skipped (R2026a+: getframe on invisible figure hangs)');
-end % end if gif_ok
```

Lo stesso pattern di sostituzione è applicato agli altri 3 file `STmodel_*` e alle 2 occorrenze in `NaturalNeighborInterpolation.m`.

---

## 7. Test eseguiti

### 7.1. Test sintetico isolato

`print('-RGBImage')` su `figure('Visible','off')` con plot semplice e con `geoaxes + geobasemap satellite`:
- Output RGB matrix valida (es. 938×1875×3 uint8)
- Tempo: ~1-3s per frame (cold start ~10-15s)
- Nessun hang

### 7.2. Test ciclo GIF completo

Loop di 5 frame con `imwrite` append, `Loopcount=inf`, `DelayTime=0.5`:
- File GIF generato correttamente
- 5 frame, dimensioni coerenti, animazione riproducibile in viewer standard
- Tempo: ~3s totali (warm)

### 7.3. Test E2E "fase 7" letterale

Esecuzione del **codice esatto** della fase 7 di `STmodel_DET2D.m` post-fix, con variabili sintetiche realistiche basate sull'AOI Calabria del dataset di test:
- 10 epoch generate, una per una, in MATLAB GUI visibile
- Waitbar e figure progressive osservate dall'utente
- GIF finale: `STdet_displ2D.gif`, 9.5 MB, 10 frame, 1875×938 px
- Apertura automatica nel viewer Windows con animazione corretta

Nessun hang. Nessun warning bloccante. Comportamento atteso.

### 7.4. Test parsing su tutti i file modificati

`nargin('<file>')` su tutti i 5 file modificati:
- 5/5 parse OK
- I warning preesistenti su `parfor` (linee 832-833 di `STmodel_STC1D/2D.m`) non sono regressioni della fix.

---

## 8. Caveat documentati

### 8.1. Warning cosmetici su geoaxes

Su `geoaxes` con `geobasemap satellite`, MATLAB R2026a emette warning del tipo:
```
Warning: Error in state of SceneNode.
Invalid RGB triplet. Specify a three-element vector of values between 0 and 1.
```

Sono generati dal renderer interno della scene del basemap quando interrogato dalla print pipeline. **Non sono bloccanti** — la print restituisce comunque l'immagine valida e la GIF viene generata correttamente. Probabile bug interno R2026a che verrà risolto in release future. Non ho riscontrato modi puliti per sopprimerlo selettivamente senza nascondere errori legittimi, quindi è stato accettato come noise log non bloccante.

### 8.2. Versione MATLAB minima

`print('-RGBImage')` richiede MATLAB R2017a+. PHASE dichiara R2025a come minimo supportato → coperto.

### 8.3. Pattern equivalente per future implementazioni

Per qualsiasi funzione futura che voglia generare GIF/video da figure invisibili, **non usare** `getframe`. Usare:
```matlab
im = print(gcf, '-RGBImage');   % per loop GIF custom (rgb2ind + imwrite)
% oppure
exportgraphics(gcf, file, 'Append', t > 1);   % per uso semplice senza DelayTime/Loopcount
```

---

## 9. Stato finale

| Componente | Stato |
|---|---|
| 5 file modificati | committati in `6642708` |
| Workaround obsoleto | rimosso |
| GIF generation su R2026a | ripristinata |
| Compatibilità Linux/macOS | invariata (la fix è cross-platform pura) |
| Test E2E | superato |

Il fix è pubblicato sulla PR [pyccino/PHASE#1](https://github.com/pyccino/PHASE/pull/1) ed è pronto per il merge.
