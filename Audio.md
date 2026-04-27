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

Precompute a note table in Haskell at assemble time:

```haskell
noteN :: Double -> Word16
noteN freq = round (3579545.0 / (32.0 * freq))

-- Equal-tempered chromatic scale, A4=440 Hz
noteTable :: [Word16]   -- indices: 0=C2, 1=C#2, ..., 71=B7
noteTable = [ noteN (440.0 * 2.0 ** ((fromIntegral i - 45) / 12.0))
            | i <- [0..71] ]
```

---

## Volume

Volume is set with a latch byte with `t=1`:

```
0x90 | (ch << 5) | (volume & 0x0F)
```

Volume is an **attenuation** value: `0` = maximum volume, `15` = silence.  Each step is
approximately 2 dB quieter.

```
OUT (0x7F), 0x9F    ; silence channel 0 (0x90 | 0x0F)
OUT (0x7F), 0x90    ; channel 0 at full volume
```

---

## Noise Channel

The noise channel is controlled by writing to its frequency register:

```
Bits 1:0  Rate:  00=N/512, 01=N/1024, 10=N/2048, 11=use tone channel 2 frequency
Bit  2    Type:  0=periodic (buzzy), 1=white noise
```

White noise at rate 2 (N/2048): `OUT (0x7F), 0xE7`  
Periodic at rate 0:            `OUT (0x7F), 0xE0`

To use tone channel 2 as the noise rate source, set noise rate = 3 and program channel 2's
frequency normally.  This allows a tuned bass drum effect.

---

## Suggested DSL Abstraction

```haskell
portPSG :: Word8
portPSG = 0x7F

-- | Channel identifiers
data PSGChannel = Tone0 | Tone1 | Tone2 | Noise
  deriving (Eq, Ord, Enum, Bounded)

-- | Set tone frequency on a channel (compile-time constant).
-- Destroys A.
setToneFreq :: PSGChannel -> Word16 -> Asm ()
setToneFreq ch n = do
  let chBits = fromIntegral (fromEnum ch) :: Word8
      lo = 0x80 .|. (chBits `shiftL` 5) .|. fromIntegral (n .&. 0x0F)
      hi = fromIntegral ((n `shiftR` 4) .&. 0x3F)
  ldi A lo; outA portPSG
  ldi A hi; outA portPSG

-- | Set channel volume (0 = max, 15 = silent). Destroys A.
setVolume :: PSGChannel -> Word8 -> Asm ()
setVolume ch vol = do
  let chBits = fromIntegral (fromEnum ch) :: Word8
      cmd = 0x90 .|. (chBits `shiftL` 5) .|. (vol .&. 0x0F)
  ldi A cmd; outA portPSG

-- | Silence all channels. Destroys A.
silenceAll :: Asm ()
silenceAll = mapM_ (\ch -> setVolume ch 15) [Tone0, Tone1, Tone2, Noise]

-- | Configure noise channel.
data NoiseConfig = NoiseConfig
  { noiseRate :: Word8   -- 0–3 (3 = use Tone2)
  , noiseWhite :: Bool   -- True = white noise, False = periodic
  }

setNoise :: NoiseConfig -> Asm ()
setNoise (NoiseConfig rate white) = do
  let typeBit = if white then 0x04 else 0x00
      cmd = 0xE0 .|. typeBit .|. (rate .&. 0x03)
  ldi A cmd; outA portPSG
```

---

## Music Data Format

Music is typically stored as a compact stream of commands in ROM, interpreted by a music
driver subroutine called once per frame (or at a fixed tick rate from the VBlank ISR).

### Simple Command Format

```
| Byte  | Meaning                                    |
|-------|--------------------------------------------|
| 0xFx  | Set channel 0 volume to x (0=max, F=silent)|
| 0xEx  | Set channel 1 volume                       |
| 0xDx  | Set channel 2 volume                       |
| 0xCN  | Set channel 0 note index N (into noteTable)|
| 0xBN  | Set channel 1 note                         |
| 0xAN  | Set channel 2 note                         |
| 0x00  | End of track (loop or stop)                |
| other | Wait N ticks                               |
```

### Music Driver Sketch

```haskell
-- RAM: ramMusicPtr (2 bytes), ramMusicTick (1 byte)

-- | Advance the music driver by one tick. Call from VBlank ISR or main loop.
-- Destroys A, HL, BC.
musicTick :: Asm ()
musicTick = do
  -- decrement wait counter
  ldAnn (Lit ramMusicTick)
  dec A
  jp_cc NZ (ref "_musicWait")
  -- fetch next command
  ldHLind (Lit ramMusicPtr)
  ldHL A                      -- A = command byte
  inc16 HL
  stHLaddr (Lit ramMusicPtr)  -- advance pointer
  -- dispatch command
  cpAn 0x00; jp_cc Z (ref "_musicEnd")
  -- ... command decode ...
  rawLabel (Label "_musicWait")
  stnn (Lit ramMusicTick)
  rawLabel (Label "_musicEnd")
```

---

## Usage Examples

### Play a C-major Arpeggio

```haskell
setVolume Tone0 0          -- channel 0 at full volume
setToneFreq Tone0 (noteN 523.25)   -- C5
waitVBlank
setToneFreq Tone0 (noteN 659.25)   -- E5
waitVBlank
setToneFreq Tone0 (noteN 783.99)   -- G5
waitVBlank
setVolume Tone0 15         -- silence
```

### Sound Effect: Explosion

```haskell
setNoise (NoiseConfig { noiseRate = 2, noiseWhite = True })
setVolume Noise 0          -- full volume
-- ... after 8 frames, fade out:
setVolume Noise 8
-- ... after 8 more:
setVolume Noise 15
```

---

## Notes

- **Write timing**: The PSG requires the CPU to write a complete command before the next write.
  At 3.58 MHz, one `OUT` instruction takes 11 T-states (~3 µs) — far longer than any SN76489
  setup time (~23 ns).  No delay is needed between bytes.
- **Stereo (GG-specific)**: The Game Gear has a hardware stereo panning register at I/O port
  `0x06`.  Each bit independently enables left/right output per channel (bits 7:4 = right
  enable, bits 3:0 = left enable).  Writing `0xFF` gives full stereo; `0x00` silences all.
- **Voice / PCM**: 1-bit PCM can be approximated by rapidly switching a channel's volume
  between 0 and 15 at the sample rate — extremely CPU-intensive and practically limited to
  8 kHz at best.  See the Roadmap "Voice" item.
- **Music vs. SFX priority**: A common pattern dedicates channels 0–1 to music and channel 2
  to SFX.  The music driver skips its channel-2 update frame while an SFX is active.
