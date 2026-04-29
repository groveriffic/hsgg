# Audio on the Game Gear

## Overview

The Game Gear uses the **SN76489** Programmable Sound Generator (PSG), integrated into the
VDP chip.  It provides:

- Three **tone channels** (square wave, programmable frequency)
- One **noise channel** (periodic or white noise, with selectable rate)
- Independent **4-bit volume** per channel (attenuation, not gain)

The PSG is a **write-only** device.  All commands are single-byte writes to port `0x7F`.

---

## Hardware: SN76489

### Port

```
OUT (0x7F), A    ; write one command byte to PSG
```

Port `0x7F` is the standard Game Gear PSG port (mirrored at other addresses on SMS; use `0x7F`
for GG).

### Command Byte Format

Every byte written to the PSG is either a **latch/data byte** (bit 7 = 1) or a **data byte**
(bit 7 = 0, used as the second byte of a two-byte tone frequency write).

#### Latch/Data Byte (bit 7 = 1)

```
Bit:  7   6  5   4    3   2   1   0
      1  [ch ch] [t]  [d  d   d   d]

ch = channel: 00=tone0, 01=tone1, 10=tone2, 11=noise
t  = type:    0=frequency/noise-control, 1=volume
d  = 4-bit data (LSBs of frequency, or volume, or noise control)
```

#### Data Byte for Tone Frequency (bit 7 = 0)

```
Bit:  7   6   5   4   3   2   1   0
      0   0  [f9  f8  f7  f6  f5  f4]

Provides the high 6 bits of the 10-bit tone frequency counter (f9:f4).
The preceding latch byte provided the low 4 bits (f3:f0).
```

Full write sequence for a tone frequency:

```
OUT (0x7F), 0x80 | (ch<<5) | (freq & 0x0F)   ; latch + low 4 bits
OUT (0x7F), (freq >> 4) & 0x3F                ; high 6 bits
```

---

## Tone Frequency Formula

```
f_out = clock / (32 × N)

clock = 3.579545 MHz (Game Gear)
N     = 10-bit counter value (1–1023; 0 is treated as 1024)
```

Solving for N given a desired frequency:

```
N = round(clock / (32 × f_out))
  = round(3579545 / (32 × f_out))
```

| Note | Frequency (Hz) | N (approx) |
|------|---------------|------------|
| A4   | 440           | 255        |
| C4   | 261.6         | 428        |
| C5   | 523.3         | 214        |
| C6   | 1046.5        | 107        |

---

## Volume

Volume is set with a latch byte with `t=1`:

```
0x90 | (ch << 5) | (volume & 0x0F)
```

Volume is an **attenuation** value: `0` = maximum volume, `15` = silence.  Each step is
approximately 2 dB quieter.

---

## Noise Channel

The noise channel is controlled by writing to its frequency register:

```
Bits 1:0  Rate:  00=N/512, 01=N/1024, 10=N/2048, 11=use tone channel 2 frequency
Bit  2    Type:  0=periodic (buzzy), 1=white noise
```

To use tone channel 2 as the noise rate source, set noise rate = 3 and program channel 2's
frequency normally.  This allows a tuned bass drum effect.

---

## DSL: `GameGear.PSG`

```haskell
portPSG :: Word8   -- 0x7F
```

### Note type

```haskell
newtype Note = Note { noteCounter :: Word16 }

quantizeHz   :: Double -> Note    -- nearest representable frequency
noteActualHz :: Word16 -> Double  -- true frequency for a counter value
```

### Tone / volume / noise

```haskell
-- Emit two OUT instructions (latch + data). Destroys A.
setToneFreq :: Word8 -> Note -> Asm ()   -- channel (0–2), note

-- Emit one OUT instruction. Destroys A.
setVolume :: Word8 -> Word8 -> Asm ()    -- channel (0–3), attenuation (0=max, 15=silent)

-- Silence all four channels. Destroys A.
silenceAll :: Asm ()

data NoiseType = WhiteNoise | PeriodicNoise

-- rate: 0=N/512, 1=N/1024, 2=N/2048, 3=use Tone2. Destroys A.
setNoise :: NoiseType -> Word8 -> Asm ()
```

### Usage example

```haskell
setVolume 0 0                          -- channel 0 at full volume
setToneFreq 0 (quantizeHz 523.25)      -- C5
-- ... after VBlank ...
setToneFreq 0 (quantizeHz 659.25)      -- E5
setVolume 0 15                         -- silence

-- Explosion SFX
setNoise WhiteNoise 2
setVolume 3 0    -- noise channel at full volume
```

---

## DSL: `GameGear.Music`

Data-driven music driver for tone channels.  Music is stored as a compact ROM table and
interpreted by a per-channel driver subroutine, typically called once per VBlank.

### Table format

Each entry is either a note (3 bytes) or a loop sentinel (1 byte):

```
Note:     [duration (frames), N & 0x0F, (N >> 4) & 0x3F]
LoopBack: [0x00]
```

### RAM layout per channel

3 bytes: `[ptrLo, ptrHi, dur]` — current read pointer (2 bytes) and remaining duration counter.

### API

```haskell
data MusicEntry
  = ToneNote Note Word8   -- frequency and duration in frames (duration > 0)
  | LoopBack              -- resets driver pointer to table start

-- Emit ROM table bytes; returns the table's start label.
-- Place inside a jp-over block so execution cannot fall into the data.
emitToneTable :: [MusicEntry] -> Asm Label

-- Emit driver subroutine; returns its label.
-- Call once per frame (or from VBlank ISR) per active channel.
-- Destroys A, HL.
emitToneDriver
  :: Word8     -- PSG channel (0, 1, or 2)
  -> Label     -- table label from emitToneTable
  -> AddrExpr  -- RAM: pointer lo byte
  -> AddrExpr  -- RAM: pointer hi byte
  -> AddrExpr  -- RAM: duration counter
  -> Asm Label
```

### Driver behaviour

1. Decrement duration counter; return early (`RET NZ`) if still nonzero.
2. Read next table entry.  `LoopBack` (`0x00` duration) resets the pointer to the table start.
3. Send frequency to PSG (two OUT writes) and store the new duration and pointer back to RAM.

### Usage example

```haskell
-- Assemble time: emit table
tbl <- emitToneTable
  [ ToneNote (quantizeHz 261.6) 16   -- C4, 16 frames
  , ToneNote (quantizeHz 329.6) 16   -- E4
  , ToneNote (quantizeHz 392.0) 32   -- G4
  , LoopBack
  ]

-- Assemble time: emit driver for channel 0
drv <- emitToneDriver 0 tbl (Lit ramPtr0Lo) (Lit ramPtr0Hi) (Lit ramDur0)

-- Runtime: call once per VBlank
call (LabelRef drv)
```

---

## Notes

- **Write timing**: At 3.58 MHz, one `OUT` takes 11 T-states (~3 µs) — far longer than the
  SN76489 setup time (~23 ns).  No delay is needed between bytes.
- **Stereo (GG-specific)**: Port `0x06` independently enables left/right output per channel
  (bits 7:4 = right enable, bits 3:0 = left enable).  `0xFF` = full stereo; `0x00` = silence.
- **Music vs. SFX priority**: A common pattern dedicates channels 0–1 to music and channel 2
  to SFX.  The music driver skips its channel update while an SFX is active.
- **Voice / PCM**: 1-bit PCM can be approximated by rapidly switching a channel's volume
  between 0 and 15 — extremely CPU-intensive.  See the Roadmap "Voice" item.
