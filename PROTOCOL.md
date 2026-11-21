# PadLink protocol (v1)

Transport: one TCP connection, Mac = client, Pad = server (Bonjour/NSD type `_padlink._tcp`, default port 47800),
TCP_NODELAY on both sides — **or** the USB cable via Android Open Accessory (manufacturer "PadLink", model
"PadLink Mac"): same byte stream over the accessory bulk pipes, ≤16 KB per transfer, never an exact multiple of
512 bytes (short-packet rule). Over USB the pad auto-approves (cable = physical consent) and the Mac allows
2 frames in flight instead of 3. All integers big-endian, floats IEEE-754 big-endian.

Every message: `[u8 type][u32 length][payload…]`

## Mac → Pad
| type | name          | payload |
|------|---------------|---------|
| 0x01 | HELLO         | UTF-8 JSON `{"v":2,"macId":"…","macName":"…","token":"…"\|null,"udpPort":n,"udpKey":n}` (udp* only on Wi‑Fi) |
| 0x02 | VIDEO_CONFIG  | u32 width, u32 height (encoded H.264 size) |
| 0x03 | VIDEO_FRAME   | u8 flags (bit0 = keyframe, bit1 = inkSeq present), u64 frameId, [u32 inkSeq], H.264 Annex-B (SPS/PPS prepended on keyframes) |
| 0x04 | PING          | u64 t |
| 0x05 | BYE           | – |
| 0x06 | INK           | u32 seq — screen is static and already shows every pen sample ≤ seq (pad drops its local ink) |
| 0x07 | INK_STYLE     | u8 r, u8 g, u8 b, f32 width (fraction of picture width), u8 visible — the stroke as measured on the Mac |

## Pad → Mac
| type | name          | payload |
|------|---------------|---------|
| 0x81 | HELLO_REPLY   | UTF-8 JSON `{"status":"ok"\|"pending"\|"denied","token":"…","padName":"…","width":2880,"height":1800}` — `pending` = pad is showing "Erlauben?", a second reply follows |
| 0x82 | PEN           | u8 action, u8 tool (0 pen, 1 eraser), u8 buttons (bit0 = side button), f32 x, f32 y (0…1 of the video frame), f32 pressure (0…1), f32 tiltX, f32 tiltY (−1…1), u32 seq (running sample number) |
| 0x83 | PONG          | u64 t (echo) |
| 0x84 | FRAME_ACK     | u64 frameId (sent after the frame was handed to the decoder) |
| 0x85 | COMMAND       | u8 command (see below) |
| 0x86 | SCROLL        | f32 dx, f32 dy (pad pixels), u8 zoom (1 = pinch → zoom) |
| 0x87 | KEYFRAME_REQ  | – |
| 0x88 | BYE           | – |

Pen actions: 0 hover-move, 1 down, 2 move, 3 up, 4 hover-exit, 5 hover-enter.

Commands: 1 undo, 2 redo, 3 brush, 4 eraser, 5 zoom in, 6 zoom out, 7 fit on screen,
8 hand tool down (space), 9 hand tool up, 10 smaller brush `[`, 11 bigger brush `]`.

## Pairing
HELLO carries the token the Mac stored for this pad. If the pad knows that token for that `macId`
it answers `ok` immediately. Otherwise it shows "Erlauben?" once; on yes it creates a token,
stores it and returns it in HELLO_REPLY. From then on: one button, no questions.

## Latency control
The pad ACKs a frame once it has been *shown*. The Mac counts frames that are being encoded or sent
but not yet shown; at 3 it simply doesn't encode new screen pictures. As soon as an ACK frees a slot it
encodes the *newest* picture. Nothing ever queues up, no keyframes are needed for recovery, and the
picture never lags behind the pen. (Tested: with 120 ms artificial delay it still runs at ~22 fps.)

## Local ink (hiding Wi‑Fi lag without faking anything)
The pad draws each pen sample itself immediately (exact samples, no prediction/smoothing). Every picture carries
`inkSeq` = the newest sample that was injected at least 60 ms before the picture was captured (time for the app to
draw it). When that picture is shown, the pad deletes its local ink up to `inkSeq`. If the screen stops changing,
INK does the same once every sent picture is shown. The Mac samples colour and thickness of the real stroke 60–250
ms behind the pen and sends INK_STYLE, so the local ink looks like the real brush; if nothing is drawn under the pen
(hand tool, selection …) `visible = 0` and the pad shows no ink. Eraser end: no local ink.

## Pen over UDP (Wi‑Fi)
Datagram to the Mac's `udpPort`: u32 udpKey, u8 n, n × PEN payload (27 bytes, oldest first; the last 4 samples,
so one lost datagram costs nothing). Every sample is also sent over TCP; the Mac handles each `seq` once.
While the pen is down on Wi‑Fi the Mac encodes at 60 % bitrate; 300 ms after lifting it returns to full and
sends a fresh keyframe.
