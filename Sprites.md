# Composite Sprites & Raster Effects

## Overview

The Game Gear VDP supports up to **64 hardware sprites** per frame, each 8×8 or 8×16 pixels.
Most game characters are larger — a 16×16 player needs four 8×8 sprites arranged in a 2×2
grid.  "Composite sprites" are this multi-hardware-sprite-per-entity pattern.

**Raster effects** use the line interrupt to change VDP registers (palette, scroll, tile base)
mid-frame, enabling split-screen backgrounds, parallax, and wavy distortion.

---

## Hardware Sprite Constraints

| Property | Value |
|----------|-------|
| Max sprites per frame | 64 |
| Max sprites per scanline | 8 (VDP stops rendering beyond 8; overflow flag set in status) |
| Sprite size | 8×8 or 8×16 (VDP reg 1 bit 1) |
| Tile base | 256 tiles selectable via VDP reg 6 |
| Coordinates | Screen space (absolute, not world) |
| Tile index range | 0–255 (8×8 mode); 0–127 pairs (8×16 mode) |
| X = 0, Y = 0xD0 | End-of-list sentinel in Y-table |

---

## Sprite Attribute Table (SAT) Recap

Two regions in VRAM:

```
satYTable  (0x3F00 – 0x3F3F):  one Y byte per sprite (64 entries)
satXNTable (0x3F80 – 0x3FFF):  X byte + tile byte per sprite (128 bytes)
```

Writing `0xD0` to any Y-table entry terminates sprite processing — all entries from that index
onward are ignored.  Always terminate the list after the last active sprite.

---

## Composite Sprites

A 16×16 entity uses four hardware sprites:

```
Sprite 0: top-left     (entityX,     entityY)
Sprite 1: top-right    (entityX + 8, entityY)
Sprite 2: bottom-left  (entityX,     entityY + 8)
Sprite 3: bottom-right (entityX + 8, entityY + 8)
```

With 8×16 mode enabled, a 16×16 entity needs only two sprites (left and right columns).

### Suggested Abstraction

```haskell
-- | Initialise a 2×2 composite sprite starting at hardware sprite @baseIdx@.
-- @tileBase@ is the tile index of the top-left tile; tiles are assumed to be
-- laid out: tileBase, tileBase+1 (top row), tileBase+2, tileBase+3 (bottom row).
-- Destroys A.
initCompositeSprite2x2 :: Word8 -> Word8 -> Word8 -> Word8 -> Asm ()
initCompositeSprite2x2 baseIdx x y tileBase = do
  initSpriteEntry baseIdx       x          y       tileBase
  initSpriteEntry (baseIdx + 1) (x + 8)    y       (tileBase + 1)
  initSpriteEntry (baseIdx + 2) x          (y + 8) (tileBase + 2)
  initSpriteEntry (baseIdx + 3) (x + 8)    (y + 8) (tileBase + 3)

-- | Update screen position of a 2×2 composite sprite from RAM (world – scroll).
-- @baseIdx@ = first hardware sprite index; @screenX@, @screenY@ = computed screen coords.
-- Destroys A.
updateCompositeSprite2x2 :: Word8 -> Word8 -> Word8 -> Asm ()
updateCompositeSprite2x2 baseIdx screenX screenY = do
  -- Y table: all four sprites share a Y base
  setVRAMAddr (satYTable + fromIntegral baseIdx)
  ldi A screenY;       outA portVDPData
  ldi A (screenY + 8); outA portVDPData  -- sprites share contiguous Y entries
  ldi A screenY;       outA portVDPData
  ldi A (screenY + 8); outA portVDPData
  -- X table: interleaved X + tile bytes
  setVRAMAddr (satXNTable + fromIntegral baseIdx * 2)
  -- top row
  ldi A screenX;       outA portVDPData  -- X
  inc16 HL                               -- skip tile byte (already set at init)
  ldi A (screenX + 8); outA portVDPData
  inc16 HL
  -- bottom row
  ldi A screenX;       outA portVDPData
  inc16 HL
  ldi A (screenX + 8); outA portVDPData
```

> **Note**: `updateCompositeSprite2x2` above is illustrative.  In practice, the X/N table
> interleaves X and tile bytes, so address arithmetic must skip the tile bytes.  The most
> efficient approach is to write X bytes only and use VRAM addresses that skip the tile byte,
> or maintain a full shadow buffer in RAM and bulk-copy it in VBlank.

---

## Animation

An animation is a sequence of tile base indices.  Each entity stores:

- `animFrame` — current frame index (0-based)
- `animClock` — countdown to next frame

On each tick, decrement `animClock`.  When it reaches zero, reload it from the animation's
period and advance `animFrame` modulo the frame count.  Then rewrite the sprite's tile byte(s)
in the SAT.

```haskell
data Animation = Animation
  { animPeriod :: Word8    -- frames per animation step
  , animTiles  :: [Word8]  -- tile base index for each frame
  }

-- | Encode an animation's tile table as ROM data.
animTileData :: Animation -> [Word8]
animTileData = animTiles

-- | Emit code to advance an animation and write the new tile to the SAT.
-- @clockAddr@   = 1-byte countdown in RAM
-- @frameAddr@   = 1-byte current frame index in RAM
-- @period@      = ticks per frame
-- @frameCount@  = total animation frames
-- @tileTableLbl@= label of the animation tile table in ROM
-- @satTileAddr@ = VRAM address of the sprite's tile byte in satXNTable
-- Destroys A, HL.
tickSpriteAnim :: Word16 -> Word16 -> Word8 -> Word8 -> Label -> Word16 -> Asm ()
tickSpriteAnim clockAddr frameAddr period frameCount tileTableLbl satTileAddr = do
  -- decrement clock
  ldAnn (Lit clockAddr)
  dec A
  jp_cc NZ (ref "_animDone")
  ldi A period
  stnn (Lit clockAddr)
  -- advance frame (wrapping)
  ldAnn (Lit frameAddr)
  inc A
  cpAn frameCount
  jp_cc NZ (ref "_animNoWrap")
  xorA A
  rawLabel (Label "_animNoWrap")
  stnn (Lit frameAddr)
  -- look up tile index from table (HL = tableBase + frame)
  ld16 HL (LabelRef tileTableLbl)
  ld D 0; ld E A; addHL DE   -- HL = table + frame
  ldHL A
  -- write to SAT
  setVRAMAddr satTileAddr
  outA portVDPData
  rawLabel (Label "_animDone")
```

---

## Sprite Flicker

When more than 8 sprites share a scanline the VDP drops the lower-priority ones.  The standard
mitigation is **rotation**: cycle which hardware sprite index maps to which entity each frame,
so no single entity is always dropped.

```haskell
-- | Rotate a sprite index: add @offset@ (modulo @total@) to @baseIdx@.
-- Used to cycle sprite priority across frames.
rotatedSpriteIdx :: Word8 -> Word8 -> Word8 -> Word8
rotatedSpriteIdx baseIdx offset total =
  (baseIdx + offset) `mod` total
```

At runtime, the offset is read from a frame counter (low 2–3 bits), giving a different
rotation each frame.

---

## Raster Effects

Raster effects modify VDP state mid-frame using the line interrupt.  Common uses:

| Effect | VDP register to change mid-frame |
|--------|----------------------------------|
| Split-screen scroll | Reg 8 or Reg 9 |
| Sky/ground palette swap | Write to CRAM via data port |
| Wavy water | Reg 8 (per-line sinusoidal offset) |
| Status bar tile base | Reg 6 |

### Setup

```haskell
-- Enable line interrupt to fire at scanline 127 (split at screen midpoint):
enableLineIRQ 127   -- from Interrupts.md
```

### ISR Pattern

```haskell
org 0x0038
isrEnter
ackVDPInterrupt   -- A = VDP status; clears flag

bit 7 A
jp_cc NZ (ref "isrVBlank")

-- Line IRQ: we are now at scanline 127
-- Switch scroll to 0 for the bottom half (HUD)
ldi A 0
vdpWriteRegA 8
-- Could also swap palette, tile base, etc.
jp (ref "isrDone")

isrVBlank <- defineLabel "isrVBlank"
-- VBlank: restore world scroll for top half of next frame
ldAnn (Lit ramScrollX)
vdpWriteRegA 8

isrDone <- defineLabel "isrDone"
isrLeave
```

### Wavy Distortion

For per-scanline wave effects, the line counter is set to `0` (fire every line), and the ISR
reads a sine table indexed by `(scanline + phase)`:

```haskell
-- Sine table: 144 entries, one per GG scanline, range ±4 (fits in signed byte)
-- Pre-computed at assembly time and stored in ROM.
sineTable :: [Word8]
sineTable = map (\i -> round (4 * sin (2 * pi * fromIntegral i / 144))) [0..143]

-- In the line ISR (IM 1):
--   Read line counter from RAM (or VDP status provides scanline if available)
--   Look up sine[line + phase]
--   Write to VDP reg 8
```

The VDP does not expose the current scanline directly; maintain a RAM counter incremented in
the ISR or read from the line counter register.

---

## Notes

- **Sprite tile base**: VDP reg 6 selects which 256-tile bank sprites use (`0xFB` = bank 0).
  Background tiles and sprite tiles share VRAM; place them in non-overlapping ranges.
- **8×16 mode**: VDP reg 1 bit 1 = 1 doubles sprite height.  Tile index must be even; the VDP
  uses the even tile for the top half and `tileIdx+1` for the bottom.
- **Per-scanline CRAM writes** are possible but very tight — only ~228 T-states per line at
  3.58 MHz, and the ISR overhead itself costs ~50.  Limit to writing 1–2 CRAM entries per line.
- **Raster effects require ISR-based interrupts** (see `Interrupts.md`).  The polling
  `waitVBlank` loop cannot be in the active display period.
