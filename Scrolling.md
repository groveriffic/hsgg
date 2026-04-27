# Scrolling on the Game Gear

## Overview

The Game Gear VDP provides hardware-assisted background scrolling through two dedicated registers.
The background tilemap is 32×28 tiles (256×224 px); the GG screen shows a 160×144 px window
into it (20×18 visible tiles).  Changing the scroll registers shifts which part of the tilemap
is visible without touching VRAM.

Sprites are positioned in absolute screen coordinates via the SAT and are **not** affected by
the scroll registers.

---

## Hardware Registers

### VDP Register 8 — Horizontal Scroll

| Bits | Meaning |
|------|---------|
| 7:0  | X offset into the tilemap (0–255, pixels) |

Increasing the value moves the viewport **right** in the tilemap, so the background appears to
scroll **left** on screen (i.e. the camera moves right through the world).  The value wraps
modulo 256 (the full tilemap width in pixels).

Written to the VDP control port (0xBF) as a standard register-write pair:

```
OUT (0xBF), scroll_x   ; value first
LD  A, 0x88            ; 0x80 | reg 8
OUT (0xBF), A          ; command second
```

### VDP Register 9 — Vertical Scroll

| Bits | Meaning |
|------|---------|
| 7:0  | Y offset into the tilemap (0–223, pixels) |

Increasing the value moves the viewport **down** in the tilemap; the background scrolls
**upward** on screen.  Values 224–255 are invalid (tilemap height is 224 px); the VDP wraps
within 224.

### VDP Register 0 — Scroll Lock Bits

Used to prevent certain areas from scrolling (useful for HUD elements):

| Bit | Meaning |
|-----|---------|
|  6  | **Row lock** — top 2 tile rows (top 16 px) are exempt from horizontal scrolling |
|  7  | **Column lock** — rightmost 8 tile columns are exempt from vertical scrolling |

`vdpInit` sets reg 0 to `0x04` (Mode 4, no locks).  Override it after `vdpInit` to activate
locks.

---

## Tilemap Geometry

```
         256 px (32 tiles)
    ┌─────────────────────────────────┐
    │  ┌──────────────────┐           │  ↑
    │  │  GG screen       │           │  │
    │  │  160 × 144 px    │           │  224 px
    │  │  (20 × 18 tiles) │           │  (28 tiles)
    │  └──────────────────┘           │  │
    │                                 │  ↓
    └─────────────────────────────────┘
          ↑ scrollX, scrollY set the top-left corner of the GG window
```

The window's top-left corner in the tilemap is `(scrollX, scrollY)`.  Both axes wrap, so
you get free infinite scrolling without repositioning the tilemap.

### Name Table Address for Tile (col, row)

```
VRAM address = nameTableBase + (row * 32 + col) * 2
             = 0x3800        + (row * 32 + col) * 2
```

---

## Timing

**Always update the scroll registers during VBlank** to avoid mid-frame tearing.

```
waitVBlank        -- wait for frame interrupt flag
vdpWriteReg 8 x  -- then update both scroll regs
vdpWriteReg 9 y
```

Mid-frame scroll changes (parallax, wavy distortion) require the **line interrupt**: enable it
via reg 0 bit 4, set the line counter in reg 10, and update the scroll register from the IRQ
handler.  This is covered in the Raster Effects section of the Roadmap.

---

## Tile Streaming

Scrolling freely requires keeping the name table up to date as the viewport moves.  The VDP
renders whatever tiles are in the name table, so tiles off the right/bottom edge of the screen
must be rewritten as they scroll into view.

**Per-pixel (or per-frame) scroll:**  
No streaming needed.  Rewrite the entire 32×28 name table when you jump to a new area; within
a single room scroll freely.

**Open-world (continuous) scroll:**  
When `scrollX` crosses a tile boundary (`scrollX % 8 == 0`), rewrite the one tile column that
just entered view (18 entries × 2 bytes each).  Similarly for vertical: rewrite one row
(20 entries) at each tile boundary crossing.

Column index entering view (horizontal scroll right):
```
visibleCol = (scrollX / 8 + 20) mod 32
```

Row index entering view (vertical scroll down):
```
visibleRow = (scrollY / 8 + 18) mod 28
```

---

## Suggested DSL Abstraction

The following additions to `Z80.Platform.GameGear` would cover the common cases.

### Compile-Time Scroll Position

```haskell
-- | Emit code to set the background scroll position to compile-time constants.
-- Must be called during VBlank.  Destroys A.
setScroll :: Word8 -> Word8 -> Asm ()
setScroll x y = do
  vdpWriteReg 8 x
  vdpWriteReg 9 y
```

### Runtime Scroll Update (value in register A)

When the scroll position is computed at runtime (held in a RAM variable or register), we need a
variant that sends A directly to the control port without clobbering it:

```haskell
-- | Emit code to write the current value of A to VDP register @regNum@.
-- A is not preserved.  Suitable for runtime register updates.
vdpWriteRegA :: Word8 -> Asm ()
vdpWriteRegA regNum = do
  outA portVDPCtrl                          -- write the value (A unchanged by OUT)
  ldi A (0x80 .|. (regNum .&. 0x0F))        -- command byte
  outA portVDPCtrl
```

### Scroll Lock Configuration

```haskell
data ScrollLock = ScrollLock
  { lockTopRows :: Bool    -- ^ Freeze top 2 rows against horizontal scroll
  , lockRightCols :: Bool  -- ^ Freeze right 8 columns against vertical scroll
  }

-- | Configure scroll lock bits in VDP register 0.
-- Call after vdpInit if you need a HUD area that doesn't scroll.
-- Destroys A.
setScrollLock :: ScrollLock -> Asm ()
setScrollLock (ScrollLock rows cols) =
  vdpWriteReg 0 (0x04                          -- Mode 4 baseline
    .|. (if rows then 0x40 else 0x00)
    .|. (if cols then 0x80 else 0x00))
```

---

## Usage Examples

### Static Scroll (compile-time offset)

Shift the background 16 pixels right and 8 pixels down on startup:

```haskell
vdpInit
-- ... load tiles, palette ...
setScroll 16 8
enableDisplay
```

### Smooth Horizontal Scroll in a Game Loop

Scroll one pixel per frame using a RAM variable:

```haskell
-- RAM layout (defined elsewhere):
--   ramScrollX = 0xC000

mainLoop <- freshLabel "mainLoop"
rawLabel mainLoop

waitVBlank

-- Read scroll X, increment, store
ldAnn (Lit ramScrollX)
inc A
stnn  (Lit ramScrollX)

-- Update VDP reg 8 with new value (A already holds it)
vdpWriteRegA 8

jp (LabelRef mainLoop)
```

### Parallax: Two-Layer Scroll

A common trick is to run the background at half the speed of the foreground.  Since the VDP
only has one background layer, the "foreground" layer must be sprites.  The background scroll
register is updated every frame at half the player's world speed:

```haskell
-- Assumes HL = player world X (16-bit).
-- Background scroll = playerX / 2 (one byte, lower precision).

ld A H         -- high byte of playerX = playerX / 256
rra            -- A = playerX / 512; carry = bit for /256
               -- (rough: use this only when parallax precision isn't critical)
vdpWriteRegA 8
```

For smoother parallax, maintain a separate 8-bit RAM counter for the background and update it
at half the rate of the player movement counter.

### HUD That Doesn't Scroll

Lock the top 2 rows so a score display stays fixed while the world scrolls horizontally:

```haskell
vdpInit
setScrollLock (ScrollLock { lockTopRows = True, lockRightCols = False })
-- fill name table rows 0-1 with HUD tiles
-- fill name table rows 2-27 with world tiles
setScroll 0 0
enableDisplay

-- In game loop: only VDP reg 8 changes; rows 0-1 are unaffected.
```

---

## Relationship to Screen Coordinates

World-space coordinates (where an entity lives) and screen-space coordinates (where it draws)
diverge once scrolling is active:

```
screenX = worldX - scrollX   (mod 256)
screenY = worldY - scrollY   (mod 224)
```

Sprite X/Y in the SAT must be in **screen space**.  When the scroll position changes, all
visible sprite positions must be recomputed or maintained as `worldX - scrollX` deltas.

This is why the Roadmap treats **Scrolling** and **Screen Coordinates** as a single feature:
the scroll offset is the transform between the two spaces, and both systems need to agree on
it to work correctly.
