# Instrumentos de TrackDrum

Las imágenes de producción están en `Sources/TrackDrum/Web/assets` y se incluyen
automáticamente con el recurso `Web` de Swift Package Manager:

| Recurso | Dimensiones |
| --- | --- |
| drums.jpg | 2400 × 1500 |
| guitar.jpg | 2400 × 1500 |
| bass.jpg | 2400 × 1500 |
| pad.jpg | 600 × 750 |
| pad-pressed.jpg | 600 × 750 |

Son JPEG (calidad 0,85): los PNG originales pesaban 22 MB y eran opacos.
`AppIcon.png` es el icono de la app; se regenera con `swift Scripts/make-icon.swift`.

`InstrumentSources` conserva las bases generadas. Para reconstruir los PNG desde
la raíz del repositorio:

```sh
swift -module-cache-path /tmp/trackdrum-module-cache Scripts/build-instrument-assets.swift
```

El script compone la geometría exacta de las cuerdas, cejuelas, trastes y marcadores
sobre las bases de madera. Guitarra: y = 20/32/44/56/68/80 %, cejuela x = 9 % y
trastes x = 20.6/30.6/39.4/47.2/54 %. Bajo: cuatro cuerdas en los centros de sus
filas y trece casillas iguales; la última barra coincide con el borde derecho.

La interfaz añade los indicadores de acordes, escala, dedos y golpes encima de
los PNG. Las nueve elipses `#zones` son el mapa común para ratón y trackpad.
Los dos modos de pads comparten las imágenes de reposo y de iluminación ámbar.

Limitaciones visuales: la batería procede de una imagen generada y sus centros
visuales son aproximados, aunque las zonas interactivas usan los porcentajes
solicitados. Las bases generadas conservan pequeñas variaciones en el fondo
casi negro y entre las siluetas de los dos estados del pad; no están certificadas
como fondo #111110 uniforme o estados idénticos píxel a píxel.

Verificado: compilación release, sintaxis JavaScript, coordenadas de zonas y
cuerdas, rasgueo de las seis cuerdas, creación de notas del bajo y dimensiones
de los cinco PNG. La verificación visual con WKWebView quedó bloqueada por las
restricciones del entorno. El autotest de audio genera los instrumentos y
efectos, pero aborta al crear la salida de AVAudioEngine/CoreAudio.
