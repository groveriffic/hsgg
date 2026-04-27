# Interrupt Handling on the Game Gear

## Overview

The Game Gear Z80 supports three interrupt sources:

| Source | Vector | Trigger |
|--------|--------|---------|
| **VBlank** (maskable) | `0x0038` | End of active display, start of vertical blank |
| **H-blank / line** (maskable) | `0x0038` | Line counter reaches zero (same vector as VBlank; must disambiguate in software) |
| **NMI / Pause** (non-maskable) | `0x0066` | User presses the Pause button |

The current DSL uses **polling** (`waitVBlank`) to synchronise with VBlank.  ISR-based
interrupts are more robust, required for H-blank raster effects, and free the CPU during
the active display period.

---

## Z80 Interrupt Modes

| Mode | Command | Behaviour |
|------|---------|-----------|
| IM 0 | `im0` | Data bus vector (not usable on GG — bus floats to `0xFF` = `RST 38h`) |
| IM 1 | `im1` | Always jumps to `0x0038` |
| IM 2 | `im2` | Vector table: reads one byte from I register + data bus, jumps to 16-bit address at that location |

**IM 1 is standard for Game Gear.**  IM 2 is more flexible (separate vectors per interrupt
source) but requires a jump table in RAM and correct setup of the I register.

Interrupts are **disabled at reset**.  Call `ei` to enable them.  The `DI`/`EI` pair is used
to create critical sections that must not be interrupted.

---

## VBlank ISR (IM 1)

### Hardware

VBlank is triggered when the VDP completes the last active scanline.  The VDP status register
(port `0xBF`) bit 7 is set at the same time; it is cleared automatically when the status port
is read (which happens during the ISR acknowledge cycle in IM 1).

The VDP must have its VBlank IRQ enabled (VDP register 1 bit 5 = 1).  `enableDisplay` already
sets this bit (`0xE0`).

### Setup

```
ROM layout at 0x0000:
  0x0000  JP main          ; reset vector
  ...
  0x0038  <VBlank ISR>     ; maskable interrupt vector (IM 1)
  0x0066  <NMI ISR>        ; NMI vector (Pause button)
```

The ROM must be assembled so that code (or a jump) sits at exactly `0x0038` and `0x0066`.

### ISR Requirements

An ISR entered via IM 1 must:

1. Save all registers it clobbers (`PUSH AF` etc.)
2. Do work (update scroll registers, flip sprite tables, etc.)
3. Restore registers
4. Return with `EI` + `RETI` (not `RET` — RETI signals the interrupt controller)

```z80
; Minimal VBlank ISR skeleton
org 0x0038
  push af
  push bc
  push de
  push hl
  ; --- ISR work here ---
  pop hl
  pop de
  pop bc
  pop af
  ei
  reti
```

### Shadow Registers

The Z80 has an alternate register set (AF', BC', DE', HL') accessible via `EX AF, AF'` and
`EXX`.  Using only the shadow registers inside the ISR avoids the push/pop overhead entirely,
provided the main code does not rely on them.

---

## NMI / Pause Button

The Pause button on the GG console is wired to the NMI pin of the Z80.  NMI:

- **Cannot be masked** by `DI`
- Always vectors to `0x0066`
- Does not read the data bus (no acknowledge cycle)
- Returns with `RETN` (not `RETI`)

A minimal NMI handler that just returns:

```z80
org 0x0066
  push af
  ; optionally toggle pause state
  pop af
  retn
```

---

## H-Blank / Line Interrupt

The VDP can generate an interrupt at the end of a specific scanline, enabling **mid-frame
effects**: palette swaps, per-line scroll changes (wavy water), split-screen scrolling.

### Setup

1. **VDP register 0 bit 4** — enable line interrupts (`0x14` with Mode 4 + line IRQ).
2. **VDP register 10** — line counter reload value.  The counter decrements each active line;
   when it reaches 0 an interrupt fires and the counter reloads.  During VBlank the counter
   always reloads from register 10.

Setting reg 10 to `N` means the interrupt fires every `N+1` lines.  Setting it to `0` fires
every line (used for per-scanline effects); setting it to `143` fires once at the bottom of
the GG's 144-line screen.

### Disambiguating VBlank vs. Line IRQ

Both share `0x0038` in IM 1.  Read the VDP status byte in the ISR:

```z80
in a, (0xBF)       ; read + clear VDP status
bit 7, a           ; bit 7 = frame (VBlank) flag
jr nz, isVBlank
; else: line interrupt
```

---

## Suggested DSL Abstraction

```haskell
-- | Emit the two-instruction VBlank ISR enable sequence.
-- Call after vdpInit and after all VRAM data is loaded.
-- Destroys A (via vdpWriteReg).
enableVBlankIRQ :: Asm ()
enableVBlankIRQ = do
  im1   -- interrupt mode 1 (vector always 0x0038)
  ei    -- enable interrupts

-- | Emit code to acknowledge and discard a VDP interrupt (read status port).
-- Use at the top of an ISR to clear the interrupt flag.
-- Destroys A.
ackVDPInterrupt :: Asm ()
ackVDPInterrupt = inA portVDPCtrl

-- | Emit an ISR prologue that saves the common clobber set.
isrEnter :: Asm ()
isrEnter = mapM_ push [AF, BC, DE, HL]

-- | Emit an ISR epilogue that restores and returns.
isrLeave :: Asm ()
isrLeave = do
  mapM_ pop [HL, DE, BC, AF]
  ei
  reti

-- | Emit code to enable line interrupts and set the line counter.
-- @lineCounter 0@ fires every line; @lineCounter 143@ fires at screen bottom.
-- Destroys A.
enableLineIRQ :: Word8 -> Asm ()
enableLineIRQ counter = do
  vdpWriteReg 0  0x14   -- Mode 4 + line IRQ bit
  vdpWriteReg 10 counter
```

---

## Usage Examples

### ISR-Based VBlank (IM 1)

```haskell
-- ROM header area
org 0x0000
jp (ref "main")

-- VBlank ISR at fixed vector
org 0x0038
isrEnter
ackVDPInterrupt

-- Update scroll registers from RAM
ldAnn (Lit ramScrollX)
vdpWriteRegA 8
ldAnn (Lit ramScrollY)
vdpWriteRegA 9

-- Signal main loop that the frame is done
ldi A 1
stnn (Lit ramFrameReady)

isrLeave

-- NMI (Pause) handler
org 0x0066
push AF
pop AF
retn

-- Main program
main <- defineLabel "main"
di
vdpInit
-- ... load tiles, palette ...
enableVBlankIRQ  -- sets IM1 + EI

gameLoop <- defineLabel "gameLoop"
-- Wait for ISR to set ramFrameReady
waitLoop <- freshLabel "_wait"
rawLabel waitLoop
ldAnn (Lit ramFrameReady)
cpAn 0
jr_cc Z (LabelRef waitLoop)

-- Clear the flag
xorA A
stnn (Lit ramFrameReady)

-- Game logic (runs during active display — full frame time available)
updatePlayer
jp (LabelRef gameLoop)
```

### Line IRQ for Split-Screen

```haskell
-- ISR checks which interrupt fired
org 0x0038
isrEnter
ackVDPInterrupt         -- A = VDP status

bit 7 A                 -- test VBlank flag
jp_cc NZ (ref "isrVBlank")

-- Line IRQ: switch to HUD scroll (no scroll)
ldi A 0
vdpWriteRegA 8
jp (ref "isrDone")

isrVBlank <- defineLabel "isrVBlank"
-- VBlank: restore world scroll for next frame
ldAnn (Lit ramScrollX)
vdpWriteRegA 8

isrDone <- defineLabel "isrDone"
isrLeave
```

---

## Notes

- **Stack in ISR**: The Z80 SP must be valid before interrupts are enabled.  Initialise SP
  to the top of RAM (`0xDFFF`) before calling `ei`.
- **Critical sections**: Wrap any multi-step RAM update that the ISR also reads/writes with
  `di` / `ei` to prevent partial reads.  Keep critical sections short.
- **Latency**: IM 1 has a fixed 2-cycle acknowledge overhead.  The GG VBlank period is
  approximately 576 T-states on the Z80 at 3.58 MHz — about 161 µs.
- **Polling vs. ISR**: The existing `waitVBlank` polling loop is sufficient when CPU time during
  active display is not needed.  Switch to ISR-based once you want to run game logic during the
  active frame or add raster effects.
