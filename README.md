# PadLink – Mac-Bildschirm auf dem Wacom MovinkPad Pro 14

## ⬇️ Download
| | |
|---|---|
| **Mac** | [PadLink-Mac.zip](https://github.com/LeanderKY/PadLink/releases/latest/download/PadLink-Mac.zip) – entpacken, `PadLink.app` in *Programme* ziehen |
| **Pad (Android)** | [PadLink.apk](https://github.com/LeanderKY/PadLink/releases/latest/download/PadLink.apk) – auf dem Pad öffnen, „Installieren“ |

Alle Versionen: [Releases](https://github.com/LeanderKY/PadLink/releases). Das Repo ist privat – zum Herunterladen
muss man bei GitHub angemeldet sein (auch auf dem Pad im Browser).

Ein großer Knopf am Mac → das Bild erscheint auf dem Pad, und der Stift malt in Photoshop (mit Druckstärke
und Neigung). Kein Kabel. Nur beim allerersten Mal wird gekoppelt („Erlauben“ auf dem Pad).

```
 Mac (PadLink.app)                              Pad (PadLink.apk, Android)
 ScreenCaptureKit → H.264 (Hardware, low-latency) ──WLAN/TCP──▶ MediaCodec (low-latency) → Bildschirm
 Tablet-Events (Druck, Neigung) ◀──────────────────────────── Stift / Gesten / Werkzeugknöpfe
```

## Benutzen (für deine Schwester)
1. Auf dem Pad **PadLink** öffnen – dort steht „Bereit“.
2. Am Mac in PadLink auf den **großen blauen Knopf** drücken.
3. Nur beim ersten Mal: auf dem Pad **Erlauben** tippen.

Fertig. Nächstes Mal: Pad-App öffnen, Knopf drücken.

**Mit Kabel (am wenigsten Verzögerung):** Pad mit USB-C-Kabel an den Mac stecken, dann den Knopf drücken.
PadLink nimmt automatisch das Kabel, wenn eins steckt, sonst WLAN. Beim allerersten Mal fragt das Pad
„PadLink öffnen?“ bzw. „USB-Zugriff erlauben?“ → *Immer* ankreuzen und bestätigen. Kein Entwicklermodus nötig
(Android Open Accessory). Unten am Mac steht dann „Verbunden per Kabel“.

**Photoshop oder Photopea:** PadLink erkennt, welches Programm vorne ist. Bei Photopea (im Browser) schicken die
Knöpfe die Photopea-Tasten (Rückgängig = Cmd+Wahl+Z, Zoom = Wahl+Mausrad). Druckstärke in Photopea: beim Pinsel
oben in der Leiste „Stylus Pressure“ für Größe/Deckkraft einschalten. Am besten in Chrome.

Auf dem Pad links gibt es große Knöpfe für Photoshop: Rückgängig, Wiederholen, Pinsel, Radierer,
Hand (gedrückt halten und mit dem Stift schieben), Zoom +/−, Ganzes Bild, Pinsel größer/kleiner, Trennen.
Zwei Finger verschieben das Bild, zwei Finger auseinander/zusammen zoomen. Ein Finger (Handballen)
wird ignoriert – man kann die Hand also ablegen.

Am Mac unten: **Bildschirm kopieren** (Spiegeln) oder **Zweiter Bildschirm** (das Pad wird ein
eigener Monitor – z. B. Photoshop-Leinwand aufs Pad, Werkzeuge auf dem Mac). Bildqualität:
Schnell / Ausgewogen / Scharf.

## Installieren

```bash
./build.sh            # baut dist/PadLink.app, dist/PadLink-Mac.zip, dist/PadLink.apk
```

**Mac:** `dist/PadLink.app` nach *Programme* ziehen. Wenn die App von einem anderen Mac kommt
(AirDrop/Download), einmal **Rechtsklick → Öffnen**. Beim ersten Start zeigt PadLink zwei Schritte
(Bildschirmaufnahme + Bedienungshilfen) – beide „Erlauben“, fertig.

**Pad (ohne Kabel):** Am Pad *Einstellungen → Über das Tablet → 7× auf „Build-Nummer“* →
*Entwickleroptionen → Kabelloses Debugging* an → „Gerät mit Kopplungscode koppeln“. Dann:

```bash
./install-pad.sh 192.168.1.50:37123 123456 192.168.1.50:41234   # Kopplungs-IP:Port, Code, Verbindungs-IP:Port
```

Alternativ `dist/PadLink.apk` per Google Drive/Mail aufs Pad schicken und dort antippen
(„Unbekannte Apps installieren“ einmal erlauben).

## Warum es sich schneller anfühlt
- Hardware-H.264 mit *Low-Latency Rate Control*, keine B-Frames, 0 Frames Encoder-Verzögerung.
- Kein Rückstau: Das Pad bestätigt jedes angezeigte Bild; ist das Netz langsam, wird gar nicht erst
  kodiert, sondern danach direkt das *neueste* Bild geschickt (siehe `PROTOCOL.md`).
- Pad: Decoder im Low-Latency-Modus (inkl. Snapdragon-Schalter), Bild sofort ohne Puffer anzeigen,
  120-Hz-Modus, **WLAN-Low-Latency-Lock** (schaltet das WLAN-Stromsparen ab),
  Stift-Events *unbuffered* (jedes Sample sofort, nicht 1× pro Frame).
- Ein lokaler Cursor-Ring folgt dem Stift ohne Verzögerung.
- **Lokale Tinte:** Das Pad zeichnet die Linie sofort selbst (genau die echten Stiftpunkte, nichts geraten) und
  ersetzt sie, sobald das Mac-Bild sie zeigt. Farbe und Dicke misst der Mac am echten Strich.
- Stift-Daten im WLAN zusätzlich per UDP (ein verlorenes Paket bremst nicht), beim Zeichnen kleinere Bilder.
- Optional (Menü „Bild“): AirDrop während des Zeichnens pausieren – weniger WLAN-Ruckler, fragt nach dem Passwort.
- Stift umdrehen = Radierer (Photoshop von selbst, Photopea: PadLink drückt E und danach wieder B).
- Tipp: Mac und Pad im **5-GHz- oder 6-GHz-WLAN**, Router nicht zu weit weg.

## Projekt
- `mac/` – SwiftUI-App (XcodeGen: `cd mac && xcodegen generate`)
- `android/` – Kotlin-App, keine Fremd-Bibliotheken (`cd android && ./gradlew assembleDebug`)
- `PROTOCOL.md` – Netzwerkprotokoll
