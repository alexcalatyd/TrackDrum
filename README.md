# TrackDrum

Convierte el MacBook en una batería y en un lanzador de loops usando sus sensores ocultos.

```sh
./run.sh                               # compila y abre
.build/release/TrackDrum --selftest    # comprueba que todos los sonidos se generan bien
```

## Qué hace
- **Trackpad = 8 pads** (4×2), multitouch, con volumen según la fuerza (área de contacto, autocalibrada).
- **Háptica** a bajo nivel (`MTActuatorActuate`): vibración según la fuerza y metrónomo háptico.
- **4 kits sintetizados**: 808, Acústico, Electro y 8-bit.
- **Tus samples**: arrastra un audio a un pad o usa «Cambiar sonido»; «Original» lo quita. Se guardan entre sesiones.
- **Looper**: graba por capas sobre 1, 2 o 4 compases, con cuantización a semicorcheas.
- **Modo loops**: 8 loops a tempo (Beat, Break, Charles, Percu, Bajo, Acordes, Arpegio, Pad) que entran en el siguiente compás.
- **Tapa = pedal del charles** (sensor de ángulo de la tapa): échala hacia atrás para abrirlo y vuelve para cerrarlo.
- **Golpe en el chasis = bombo** (acelerómetro oculto de Apple Silicon), con filtros para no confundirlo con el trackpad, el teclado o los altavoces.

## Cómo se usa
Al abrirla por primera vez sale una guía de 5 pasos (se puede volver a ver con el botón **?**).
Todo tiene su botón; algunos atajos: Espacio (play/stop), R (grabar), Z (deshacer), C (borrar),
M (metrónomo), Tab (Batería/Loops), 1–4 (kit), ↑↓ (tempo).

Hay dos modos:
- **Modo ratón** (al abrir): el trackpad funciona normal para usar la interfaz y no suena nada.
- **Modo tocar** (⏎ o «Empezar a tocar»): el trackpad es la batería y el cursor se bloquea y se oculta.
  Todo se controla con el teclado (hay una leyenda en pantalla) y **Esc** devuelve el ratón.

## Por dentro
- `Sources/CMultitouch`: puente en C con `MultitouchSupport` (privado), el motor háptico y los sensores HID (tapa: page 0x20/usage 0x8A; acelerómetro: AppleSPU page 0xFF00/usage 3).
- `AudioEngine.swift`: sampler propio dentro de `AVAudioSourceNode` (búfer de 128 muestras), con voces, metrónomo, looper y loops sincronizados al sample.
- `Kits.swift`, `Loops.swift`, `DSP.swift`: toda la síntesis.
- `Web/index.html`: la interfaz (WKWebView) con componentes al estilo shadcn/ui y Magic UI.

Usa APIs privadas: no es apta para la App Store.
