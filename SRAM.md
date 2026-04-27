# SRAM / Save Data

## Overview

Some Game Gear cartridges include **battery-backed SRAM** — a small amount of non-volatile
RAM that persists when the console is powered off.  The Sega mapper exposes it through the
same `0x8000–0xBFFF` window used for bank switching (slot 2), controlled by the RAM control
register at `0xFFFC`.

This is a **cartridge-level hardware feature** — not all GG cartridges have SRAM.  The ROM
header must declare that SRAM is present for the emulator (and flashcart) to enable it.

---

## Hardware

### RAM Control Register (`0xFFFC`)

| Bit | Meaning |
|-----|---------|
|  3  | Enable cartridge RAM in slot 2 (`0x8000–0xBFFF`) instead of ROM bank |
|  4  | Enable cartridge RAM in slot 1 (`0x4000–0x7FFF`) — rarely used |
|  7  | Write-protect SRAM (0 = writable, 1 = read-only) |

To enable SRAM for reading and writing:

```z80
LD A, 0x08      ; bit 3 set
LD (0xFFFC), A
```

To disable (restore ROM bank in slot 2):

```z80
LD A, 0x00
LD (0xFFFC), A
```

### Address Space When SRAM Is Enabled

```
0x8000 – 0xBFFF   Cartridge SRAM (16 KB, though most carts have 8 KB at 0x8000–0x9FFF)
```

SRAM is accessed like ordinary RAM: `LD A, (0x8000)` reads the first SRAM byte.

### Capacity

Standard SRAM cartridges contain **8 KB** (Sega standard) mapped at `0x8000–0x9FFF`.
The upper 8 KB (`0xA000–0xBFFF`) mirrors it.  Treat SRAM as exactly 8 KB to be safe.

---

## ROM Header Declaration

The Game Gear ROM header at `0x7FF0` includes a feature byte that must declare SRAM:

| Byte offset | Name | Value for SRAM cart |
|-------------|------|---------------------|
| `0x7FF6` | Region / feature flags | `0x05` (overseas + SRAM) or consult GG header spec |

The exact encoding depends on the header format in `ROM/GameGear.hs`.  An `ROMConfig` field
like `hasSRAM :: Bool` should be added to set this bit.

---

## Save Data Layout

8 KB of SRAM = 8,192 bytes.  A typical layout:

```
0x8000  Magic number    2 bytes  (e.g. 0xABCD to detect valid save)
0x8002  Checksum        1 byte   (sum of all save bytes)
0x8003  Save version    1 byte
0x8004  Player X        2 bytes  (world space)
0x8006  Player Y        2 bytes
0x8008  Current level   1 byte
0x8009  Health          1 byte
0x800A  Inventory flags 4 bytes
...
```

Always write a magic number and checksum so the game can detect a fresh (unwritten) or
corrupted SRAM and fall back to default values.

---

## Suggested DSL Abstraction

```haskell
-- SRAM base address
sramBase :: Word16
sramBase = 0x8000

-- SRAM magic value (choose any 2-byte constant)
sramMagic :: Word16
sramMagic = 0xABCD

-- | Enable SRAM (maps cartridge RAM into slot 2). Destroys A.
enableSRAM :: Asm ()
enableSRAM = do
  ldi A 0x08
  stnn (Lit regRAMCtrl)   -- 0xFFFC

-- | Disable SRAM (restores ROM bank in slot 2). Destroys A.
disableSRAM :: Asm ()
disableSRAM = do
  ldi A 0x00
  stnn (Lit regRAMCtrl)

-- | Write-protect SRAM. Destroys A.
protectSRAM :: Asm ()
protectSRAM = do
  ldi A 0x88   -- bit 3 (enable) + bit 7 (write-protect)
  stnn (Lit regRAMCtrl)

-- | Emit code to validate SRAM magic number.
-- If valid: falls through (load save data).
-- If invalid: jumps to @onFresh@ (initialise defaults).
-- Destroys A, HL.
checkSRAMValid :: Label -> Asm ()
checkSRAMValid onFresh = do
  ldAnn (Lit sramBase)
  cpAn (fromIntegral (sramMagic .&. 0xFF))
  jp_cc NZ (LabelRef onFresh)
  ldAnn (Lit (sramBase + 1))
  cpAn (fromIntegral (sramMagic `shiftR` 8))
  jp_cc NZ (LabelRef onFresh)

-- | Compute and write checksum over @count@ bytes starting at @startAddr@.
-- Checksum = sum of all bytes (mod 256), stored at @checksumAddr@.
-- Destroys A, B, HL.
writeSRAMChecksum :: Word16 -> Word16 -> Word8 -> Asm ()
writeSRAMChecksum startAddr checksumAddr count = do
  ld16n HL startAddr
  xorA A
  ldi B count
  loopLbl <- freshLabel "_csumLoop"
  rawLabel loopLbl
  ldHL C          -- C = next byte
  addA C          -- A += byte
  inc16 HL
  djnz (LabelRef loopLbl)
  stnn (Lit checksumAddr)
```

---

## Usage Examples

### Save Game

```haskell
saveGame :: Asm ()
saveGame = do
  enableSRAM

  -- Write magic number
  ldi A (fromIntegral (sramMagic .&. 0xFF))
  stnn (Lit sramBase)
  ldi A (fromIntegral (sramMagic `shiftR` 8))
  stnn (Lit (sramBase + 1))

  -- Write player position
  ldAnn (Lit ramPlayerX)
  stnn (Lit (sramBase + 4))
  ldAnn (Lit (ramPlayerX + 1))
  stnn (Lit (sramBase + 5))

  -- ... write other fields ...

  -- Compute and store checksum (over 14 bytes of save data starting at sramBase+2)
  writeSRAMChecksum (sramBase + 2) (sramBase + 2) 14

  protectSRAM   -- write-protect to prevent accidental corruption
```

### Load Game

```haskell
loadGame :: Asm ()
loadGame = do
  enableSRAM

  freshSave <- defineLabel "freshSave"
  checkSRAMValid freshSave   -- jumps to freshSave if magic not found

  -- Load player position from SRAM
  ldAnn (Lit (sramBase + 4))
  stnn (Lit ramPlayerX)
  ldAnn (Lit (sramBase + 5))
  stnn (Lit (ramPlayerX + 1))
  -- ... load other fields ...

  jp (ref "loadDone")

  rawLabel freshSave
  -- No valid save: set default values
  ldi A 0x00; stnn (Lit ramCurrentLevel)
  ldi A 3;    stnn (Lit ramPlayerHP)
  -- ...

  loadDone <- defineLabel "loadDone"
  disableSRAM
```

---

## Notes

- **Enable/disable window**: Keep SRAM enabled only for the duration of the read or write.
  Leaving it enabled permanently means slot 2 never maps ROM, which breaks any code expecting
  banked data there.
- **Write-protect after saving**: Write-protecting SRAM immediately after the save prevents
  stray writes from corrupting save data during gameplay.
- **Emulator support**: Emulicious and most GG emulators persist SRAM to a `.sav` file
  alongside the ROM automatically when the ROM header declares SRAM presence.
- **No SRAM cartridge**: If the cartridge has no SRAM, writes to `0x8000–0xBFFF` after setting
  bit 3 of `0xFFFC` are silently ignored on original hardware.  In an emulator, the write may
  land in system RAM mirror space — always check the ROM header setting.
- **Bank switching interaction**: SRAM uses the same slot 2 window as bank-switched ROM page 2.
  The two features are mutually exclusive in slot 2 — establish a convention: SRAM is accessed
  only during load/save routines in bank 0, and slot 2 is restored to a ROM bank before
  returning to gameplay.
