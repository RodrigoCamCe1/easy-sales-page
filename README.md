# EasySales Audio Bar

Barra flotante para capturar audio del sistema en Windows (Stereo Mix o dispositivos virtuales) y generar respuestas en tiempo real con OpenAI Realtime.

## Requisitos

- Windows 10/11
- Flutter instalado y configurado
- FFmpeg en PATH
- Acceso a un dispositivo de captura de salida:
  - Opcion A: Stereo Mix habilitado (Realtek o similar)
  - Opcion B: VB-Audio Cable / VoiceMeeter (recomendado si Stereo Mix no funciona)

## Instalacion

1) Instalar dependencias:

```
flutter pub get
```

2) Asegurar que `ffmpeg` esta en el PATH:

```
ffmpeg -hide_banner -version
```

### Usar el FFmpeg incluido en el repo

Si tienes `ffmpeg-2026-01-12-git-21a3e44fbe-essentials_build.7` en la raiz del proyecto, primero descomprímelo. Es mejor tenerlo descomprimido para apuntar directo a la carpeta `bin`.

1) Agrega la carpeta `bin` al PATH de Windows:

```
<RUTA_AL_PROYECTO>\ffmpeg-2026-01-12-git-21a3e44fbe-essentials_build\bin
```

2) Verifica en una nueva terminal:

```
ffmpeg -hide_banner -version
```

3) Configurar `.env` (ver ejemplo abajo).

## Configuracion de audio (Windows)

### A) Stereo Mix

1) Panel de control -> Sonido -> Grabacion.
2) Habilitar "Stereo Mix".
3) Doble clic -> Niveles (subir volumen, sin mute).
4) Verificar que el medidor se mueve cuando suena audio.
5) Usar el nombre exacto en `WINDOWS_AUDIO_DEVICE`.

Para listar dispositivos:

```
ffmpeg -list_devices true -f dshow -i dummy
```

Busca "Stereo Mix (Realtek(R) Audio)" y usa ese nombre.

### B) VB-Audio Cable / VoiceMeeter

1) Instalar VB-Audio Cable o VoiceMeeter.
2) En Windows, poner la salida de audio en "CABLE Input".
3) Capturar "CABLE Output" con dshow.
4) Configurar `WINDOWS_AUDIO_DEVICE` con el nombre exacto.

## Variables de entorno (.env)

Ejemplo minimo:

```
OPENAI_API_KEY=sk-...
OPENAI_REALTIME_MODEL=gpt-4o-realtime-preview
SYSTEM_PROMPT=Eres Sales Copilot de Control Facilito...

WINDOWS_AUDIO_BACKEND=dshow
WINDOWS_AUDIO_DEVICE=Stereo Mix (Realtek(R) Audio)
WINDOWS_AUDIO_SAMPLE_RATE=48000

# Ajustes realtime opcionales
OPENAI_VAD_SILENCE_MS=1000
OPENAI_REALTIME_FLUSH_SECONDS=6
```

Notas:
- `WINDOWS_AUDIO_SAMPLE_RATE` puede ir vacio si el dispositivo falla con ese sample rate.
- `OPENAI_VAD_SILENCE_MS` controla cuanto silencio espera antes de responder.
- `OPENAI_REALTIME_FLUSH_SECONDS` controla cada cuanto se pide respuesta.

## Prompt personalizado

El prompt se lee desde `prompt.txt` (en el directorio donde ejecutas `flutter run`).
Si cambias el prompt desde la ventana de configuracion, se guarda en `prompt.txt`.

## Uso

1) Ejecuta:

```
flutter run -d windows
```

2) Presiona "Iniciar" para capturar audio.
3) Presiona "Detener" para cerrar la sesion.
4) Configurar abre una ventana separada para editar el prompt.

## Solucion de problemas

- RMS cerca de -80 dBFS o menor: la fuente esta en silencio.
  - Verifica Stereo Mix o el dispositivo virtual.
- FFmpeg se cierra:
  - Revisa el dispositivo exacto y el sample rate.
  - Prueba con `WINDOWS_AUDIO_SAMPLE_RATE=` vacio.
- No se ve el prompt:
  - Asegura que `prompt.txt` existe en el directorio de ejecucion.

## Estructura relevante

- `lib/main.dart`: UI, captura de audio y OpenAI Realtime
- `prompt.txt`: prompt activo
