MEMVIEW.R4X
===========

MEMVIEW.R4X ist die Desktop-nahe Speicheruebersicht fuer R4OS.

Projektstruktur seit 0.51.18:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\MemView
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\MemView\zig-out\MEMVIEW.R4X

Contract:
- R4XStart-Entry: `memview_main`
- App-Klasse: `gui`
- R4L-Imports: `R4DESK:Query:1`, `R4DRAW:Query:1`, `R4DEV:Query:1`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\DESKTOP\MEMVIEW.R4X`

