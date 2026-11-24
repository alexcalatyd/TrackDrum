# TrackDrum — handoff (24-11-2026, 2ª sesión)

App nativa de macOS (Swift + WKWebView) que convierte el trackpad del MacBook en instrumentos. Se lanza con `./run.sh`: compila en release y la arranca con `sudo`, porque el acelerómetro solo manda datos como root. Hay un autotest de sonidos: `.build/release/TrackDrum --selftest`.

**Nada de esta sesión está commiteado.** El último commit es `bbcad3b` (versión antigua con pads + loops). Todo lo de abajo está en el working tree.

## Qué se hizo en esta sesión

1. **Interfaz rehecha desde cero** (`Web/index.html`). El usuario pidió quitar la "estética IA": fuera degradados, brillos, tarjetas, guía de bienvenida y barra de pistas. Ahora es oscuro plano, con líneas finas, un solo acento naranja (`--accent`) y un color por instrumento. Arriba están las pantallas y el transporte; abajo, las pistas. Los ajustes van en el engranaje.
2. **Cuatro pantallas** (teclas 1–4):
   - **Pads**: rejilla de 4×2 sobre el trackpad. Admite samples propios (botón o arrastrar el archivo).
   - **Batería**: dibujo SVG de una batería. El trackpad hace de mapa 1:1 del dibujo mediante las `<ellipse class="zone">`, que JS manda a Swift como `drumLayout`. El dibujo es provisional: **el usuario lo va a rediseñar con ChatGPT**; si cambia el dibujo, solo hay que ajustar las zonas.
   - **Guitarra**: Karplus-Strong en tiempo real (`Guitar.swift`), afinación verificada a 0 cents, con 3 tonos (acústica, eléctrica, distorsión). Los acordes van en las teclas A–Ñ y Z–N (códigos `KeyA`… y `Semicolon`). Se rasguea deslizando en vertical por el trackpad; las 6 cuerdas están en `y = 0.2…0.8` (la 0 es el Mi grave, arriba). El rasgueo se detecta en `AppController.strum`.
   - **Beats**: secuenciador de 16 pasos × 8 filas con presets (`Beats.swift`), swing, volumen y "Pasar a pista" (renderiza el patrón dentro de una pista de audio).
3. **Motor multipista** (`AudioEngine.swift`):
   - 6 pistas de audio reales en búferes preasignados (máximo 8 compases a 50 BPM).
   - El reloj es entero: `frame` cuenta muestras y cada semicorchea dura exactamente `stepFrames` muestras.
   - Al grabar, R graba el bus "live" en la pista seleccionada, con un compás de cuenta atrás.
   - Hay deshacer de la última toma (⌘Z) y exportación a WAV del loop completo.
   - Con audio grabado, **el tempo queda bloqueado**.
   - **Los loops antiguos (`Loops.swift`) se eliminaron**; los sustituye la pantalla de Beats.
4. **Cambio de salida de audio** (cascos ↔ altavoces):
   - Se reengancha por tres vías: la notificación `AVAudioEngineConfigurationChange`, el listener de CoreAudio sobre el dispositivo de salida por defecto y un vigilante cada 1 s.
   - Si falla, reintenta con espera.
   - Fija la salida explícitamente con `kAudioOutputUnitProperty_CurrentDevice`.
5. **Latencia con Bluetooth** (`AudioDevice.swift` y la calibración en `main.swift`):
   - La latencia es la mayor de dos: la de AVAudioEngine o la que declara CoreAudio (`reportedLatency`).
   - Prueba de calibración de 16 clics (toca el trackpad o pulsa espacio con cada clic). El resultado se guarda por UID de dispositivo en `UserDefaults` (`latency.<uid>`). El usuario calibró sus cascos: **162 ms**.
   - La grabación escribe en `pos - latencia` para que las tomas caigan en su sitio.
   - "Respuesta inmediata" (`TouchInput.instant`): el golpe suena en el primer fotograma del toque. Se activa sola con Bluetooth.
6. **Acelerómetro (golpe = bombo)**: decía "no disponible" aunque la app corría como root. Diagnóstico: la app abre el dispositivo (usage page 0xFF00, usage 3) y en el ioreg sus eventos aumentaban, pero `ReportInterval` estaba en 0 y a la app no le llegaba nada. Se añadió un vigilante en `AccelKick`: si deja de recibir datos, llama a `accel_wake()` cada segundo y, tras 3 s sin datos, reabre el sensor con `accel_start`, que ya es reiniciable.


## Segunda sesión: lo que se añadió (sin commitear tampoco)

Copia del estado anterior en el scratchpad de esa sesión (`backup-antes.tgz`).

- **Proyectos** (`Project.swift`): carpeta `Nombre.trackdrum` con `proyecto.json` + un WAV por pista y escena (`A-1.wav`). Menú en el nombre del proyecto (arriba a la izquierda): Nuevo ⌘N, Abrir ⌘O, Guardar ⌘S, Guardar como ⇧⌘S, Exportar ⌘E, Exportar pistas. Autoguardado en `~/Library/Application Support/TrackDrum/Autoguardado.trackdrum` cada 20 s si cambia algo, al salir (⌘Q) y con Ctrl+C en el terminal. Como la app corre con sudo, los archivos se escriben en la carpeta del usuario real (`SUDO_USER`) y se le devuelven con `chown`. Por defecto, los proyectos van a `~/Music/TrackDrum`.
- **Motor estéreo** (`AudioEngine.swift`): por pista hay volumen, paneo, mute, **solo** y envíos a reverb y delay (botón ⋯ de cada pista, que también tiene Duplicar y Vaciar). El directo usa los envíos de la pista seleccionada.
- **Efectos** (`Effects.swift`): reverb tipo Freeverb, delay ping-pong sincronizado (1/8, 1/8 con puntillo, 1/4) y compresor en el máster. Se ajustan en el botón "Efectos" de la barra de pistas.
- **Cuantizar** (No · 1/16 · 1/8, con fuerza): solo afecta a los golpes (pads, batería y sampler). Grabando, el golpe se escribe ya cuantizado en la pista y suena por un bus de monitor que no se graba. Guitarra, bajo y teclado se graban tal cual.
- **Reemplazar**: si está activo, la toma borra lo que había en la pista. Si no, se suma (overdub, como antes).
- **Escenas A–D**: cada escena tiene su audio y su ritmo; las pistas (mezclador) se comparten. Si cambias de escena mientras suena, el cambio espera al final del loop. **Canción**: cadena de escenas que avanza en cada loop; la exportación exporta la canción entera (+3 s de cola). Si cambia la escena mientras grabas, la grabación se para.
- **Exportar**: la mezcla va en estéreo y con efectos; un loop suelto se renderiza dos veces para que las colas empalmen. "Pistas por separado" escribe un WAV por pista (en seco, con su volumen y paneo), además de `Beats.wav` y `Mezcla.wav`.
- **Bajo** (`BassSynth` en `Guitar.swift`): Karplus-Strong de 4 cuerdas. El trackpad es el mástil: 4 cuerdas en vertical y 13 posiciones (al aire + 12 trastes). Tonos: Dedos, Púa y Sub, y opción "Apagar al soltar". El dibujo marca las notas de la escala.
- **Teclado** (`Synth.swift`): sinte polifónico (2 sierras + sub, filtro SVF). En horizontal están las notas de la escala (2 octavas), en vertical el brillo, y apretar más da vibrato. Sonidos: Pad, Lead y Pluck, con octava ±2.
- **Sampler**: 8 pads con las notas de la escala (abajo los graves). Por defecto suena un piano eléctrico FM; se puede cargar un sonido propio (botón o arrastrando el archivo) y afinarlo ± semitonos.
- **Tonalidad común** (tónica + escala) para el bajo, el teclado y el sampler.
- **Vibración al tocar** (ajuste): en golpes, cuerdas y bajo, y un "clic" al pasar de nota en el teclado.
- **Salida MIDI** (`Midi.swift`, ajuste): fuente virtual «TrackDrum». Canales: 1 guitarra, 2 bajo, 3 teclado (+ CC74 para el brillo), 4 sampler y 10 batería (mapa GM). Los beats del secuenciador no mandan MIDI.
- El autotest ahora también comprueba el bajo, el sinte, los efectos, la canción A-B, el paneo y guardar y abrir un proyecto.

### Sin probar con hardware
Nada de lo nuevo se ha tocado con el trackpad ni con oídos: bajo, teclado, sampler, cuantizar en directo y efectos en tiempo real. **El MIDI corriendo con sudo** puede no aparecer en el DAW del usuario (el servidor MIDI es por sesión); si pasa, habrá que probar sin sudo.

## Pendiente / sin verificar

- **Nada de lo siguiente se ha probado con hardware real**: rasgueo con el trackpad, mapa de la batería, cambio de cascos tras el último arreglo, arreglo del acelerómetro. Solo se verificó que compila, el selftest, la afinación de la guitarra y capturas de la interfaz con estado simulado.
- **Acelerómetro**: no se sabe si el arreglo funciona. Si sigue fallando, el terminal de `run.sh` muestra "el acelerómetro no responde, lo reabro" o "no se pudo abrir el acelerómetro".
- Queda un warning inofensivo en `AudioDevice.swift:42` (puntero genérico `T`; solo se usa con tipos POD).
- Falta hacer commit cuando el usuario lo pida.

## Cómo verificar cambios de UI sin lanzar la app

En el scratchpad de la sesión anterior había un `snap.swift`: carga `index.html` con un `TD.frame(...)` simulado en un WKWebView y guarda un PNG. Chrome no está instalado y Brave en modo headless se cuelga. Antes de dar la UI por buena, pasa `node --check` sobre el `<script>`: una vez una variable duplicada dejó la interfaz en blanco.

## Preferencias del usuario

- Respuestas en español, tono informal, cortas.
- No quiere interfaces con aspecto "IA" (gradientes, glow, tarjetas, badges, muchos elementos a la vez).
- La parte gráfica de la batería y la guitarra la rediseñará con ChatGPT: lo importante aquí es la funcionalidad.

## Tercera sesión: pulido para usarla como app (sin commitear)

- **Fuera el sudo**: el acelerómetro lo lee un ayudante (`AccelHelper.swift`): el mismo ejecutable con `--accel-daemon`, instalado como LaunchDaemon (`/Library/LaunchDaemons/com.trackdrum.accel.plist` + `/Library/PrivilegedHelperTools/com.trackdrum.accel`). Se instala una vez desde Ajustes → «Activar» (pide contraseña con osascript). La app le saluda por UDP 127.0.0.1:47321 cada segundo y recibe x,y,z; sin saludos durante 3 s apaga el sensor (`accel_stop`). Con `./run.sh --sudo` se sigue leyendo directo como root. **Sin probar con hardware.**
- **TrackDrum.app**: `Scripts/build-app.sh` compila, monta el bundle (web en `Contents/Resources/Web`; `WebUI` la busca ahí antes que en `Bundle.module`), crea el icono, firma ad hoc e instala en /Applications. `--no-install` la deja en `build/`.
- **Icono**: `Scripts/make-icon.swift` → `Art/AppIcon.png` (trackpad oscuro, 4×2 pads, uno naranja).
- Menú nativo (Archivo/Edición/Ventana) que llama a `handle()`; alerta en vez de `fatalError` si no arranca el audio; imágenes a JPEG (22 MB → 2,5 MB); sin el doble marco de los pads; warning de `AudioDevice` quitado.
- Ojo: al no correr como root, los ajustes de `UserDefaults` (calibración de 162 ms incluida) se leen de otro dominio: hay que recalibrar los cascos una vez.
- **Idioma** (`Lang.swift` + diccionario `EN` en `index.html`): Ajustes → Idioma (Automático / English / Español). Automático = español si el primer idioma del Mac es español; si no, inglés. La web está escrita en español y `T("texto")` la traduce; `translateDom()` traduce el HTML fijo. Los textos nuevos hay que añadirlos al diccionario `EN` (y en Swift, con `L("es", "en")`). Los nombres de pista se guardan en español (son datos) y se traducen al mostrarlos.
