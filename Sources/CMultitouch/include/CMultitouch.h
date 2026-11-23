#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

// ---------------------------------------------------------------------------
// MultitouchSupport (framework privado). Estructura obtenida por ingeniería
// inversa de la comunidad: 96 bytes por dedo.
// ---------------------------------------------------------------------------

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;           // 3 = empieza contacto, 4 = tocando, 5 = suelta...
    int fingerId;
    int handId;
    MTVector normalized; // posición 0..1 (y = 0 abajo)
    float size;          // área de contacto (aprox. presión)
    int zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;   // milímetros
    int zero2[2];
    float density;
} MTTouch;

typedef void (*MTFrameCallback)(const MTTouch *touches, int count, double timestamp);

/// Carga el framework y empieza a escuchar todos los trackpads.
/// Devuelve el número de dispositivos iniciados (0 = error).
int mt_start(MTFrameCallback callback);
void mt_stop(void);

/// Dispara el motor háptico del trackpad (1 = suave ... 6 = fuerte).
/// Devuelve 0 si ha ido bien.
int mt_haptic(int actuationID);

// ---------------------------------------------------------------------------
// Sensores ocultos vía IOKit HID
// ---------------------------------------------------------------------------

/// Ángulo de la tapa en grados, o -1 si no hay sensor.
int lid_angle(void);

typedef void (*AccelCallback)(double x, double y, double z);

/// Arranca el acelerómetro oculto en un hilo propio (~800 Hz, en g).
/// Devuelve 1 si se encontró el sensor.
int accel_start(AccelCallback callback);

#endif
