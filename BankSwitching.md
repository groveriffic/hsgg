# Bank Switching

## Overview

Without bank switching the DSL is limited to **32 KB ROMs** — the Z80's full address space is
64 KB, but the upper 32 KB (`0x8000–0xFFFF`) is occupied by RAM (`0xC000–0xDFFF`) and
mirrored I/O.  The Sega mapper extends this to **512 KB** by dividing ROM into 16 KB pages
(banks) and making three 16 KB slots in the lower address space (`0x0000–0xBFFF`) switchable
at runtime.

Most Game Gear games are ≤256 KB (16 banks).  The full mapper supports 32 banks.

---

## Sega Mapper Hardware

### Address Space Layout

```
0x0000 – 0x3FFF   Slot 0   (16 KB) — usually fixed to bank 0
0x4000 – 0x7FFF   Slot 1   (16 KB) — switchable
0x8000 – 0xBFFF   Slot 2   (16 KB) — switchable (or cartridge RAM)
0xC000 – 0xDFFF   System RAM       — not banked
0xE000 – 0xFFFF   RAM mirror + mapper registers
```

### Mapper Registers (in RAM, top of address space)

| Address | Name | Purpose |
|---------|------|---------|
| `0xFFFC` | RAM control | Bit 3 = slot 2 cartridge RAM; bit 4 = slot 1 RAM; bit 7 = write-protect SRAM |
| `0xFFFD` | Slot 0 bank | Bank number mapped into `0x0000–0x3FFF` (usually 0; changing it makes the reset vector inaccessible) |
| `0xFFFE` | Slot 1 bank | Bank number mapped into `0x4000–0x7FFF` |
| `0xFFFF` | Slot 2 bank | Bank number mapped into `0x8000–0xBFFF` |

Writing any value to `0xFFFD`–`0xFFFF` takes effect immediately.  The previous bank contents
are no longer visible in that slot until switched back.

### Bank 0 Is Always Visible at Reset

Bank 0 is the only bank guaranteed accessible at boot (reset vector `0x0000` must be in
bank 0).  Slot 0 should remain as bank 0 throughout the game; all startup code, interrupt
vectors (`0x0038`, `0x0066`), and the mapper initialisation code live there.

---

## Bank Layout Strategy

Suggested 32 KB bank organisation for a small-to-medium game:

```
Bank 0  (0x0000–0x3FFF): reset/ISR vectors, startup, mapper init, music driver,
                          sprite/entity engine — code that must always be reachable
Bank 1  (0x4000–0x7FFF): level 1 tile data + name table data
Bank 2  (0x4000–0x7FFF): level 2 tile data
Bank 3  (0x4000–0x7FFF): audio data (instrument tables, music streams)
...
```

Slot 1 (`0x4000–0x7FFF`) is the primary switchable window.  Bank 0 provides a "trampoline"
subroutine that switches slot 1, calls a function, and switches back — avoiding the need for
callers to manage the bank state themselves.

---

## Initialising the Mapper

At startup, initialise all three mapper registers explicitly (they may contain garbage at
power-on):

```z80
ld a, 0
ld (0xFFFD), a   ; slot 0 = bank 0
ld a, 1
ld (0xFFFE), a   ; slot 1 = bank 1  (starting bank)
ld a, 2
ld (0xFFFF), a   ; slot 2 = bank 2  (or 0 if not used)
ld a, 0
ld (0xFFFC), a   ; RAM control: no cart RAM, SRAM disabled
```

---

## Suggested DSL Abstraction

```haskell
-- Mapper register addresses
regRAMCtrl  :: Word16; regRAMCtrl  = 0xFFFC
regSlot0    :: Word16; regSlot0    = 0xFFFD
regSlot1    :: Word16; regSlot1    = 0xFFFE
regSlot2    :: Word16; regSlot2    = 0xFFFF

-- | Emit mapper initialisation (call from startup, before any bank-dependent code).
-- @slot1Bank@ and @slot2Bank@ are the initial banks for slots 1 and 2.
-- Destroys A.
initMapper :: Word8 -> Word8 -> Asm ()
initMapper slot1Bank slot2Bank = do
  ldi A 0;          stnn (Lit regSlot0)
  ldi A slot1Bank;  stnn (Lit regSlot1)
  ldi A slot2Bank;  stnn (Lit regSlot2)
  ldi A 0;          stnn (Lit regRAMCtrl)

-- | Switch slot 1 to the given bank. Destroys A.
bankSlot1 :: Word8 -> Asm ()
bankSlot1 bank = do
  ldi A bank
  stnn (Lit regSlot1)

-- | Switch slot 2 to the given bank. Destroys A.
bankSlot2 :: Word8 -> Asm ()
bankSlot2 bank = do
  ldi A bank
  stnn (Lit regSlot2)

-- | Switch slot 1 at runtime (bank number in A at call time).
-- Destroys nothing — uses LD (nn), A directly.
bankSlot1FromA :: Asm ()
bankSlot1FromA = stnn (Lit regSlot1)
```

### Far-Call Trampoline

Code in slot 1 cannot call code in another slot 1 bank directly — the bank would be switched
out from under the caller.  All reusable subroutines must live in bank 0 (slot 0).

For data-in-bank patterns (reading level tile data), bank 0 provides a trampoline:

```haskell
-- | Emit a trampoline that switches slot 1 to @bank@, calls @target@ (which
-- must be in bank 0 or the new bank), then restores the previous slot 1 bank.
-- Destroys A.  @prevBankAddr@ = RAM address to save the current bank number.
farCall :: Word8 -> Label -> Word16 -> Asm ()
farCall bank target prevBankAddr = do
  -- save current slot 1 bank
  ldAnn (Lit regSlot1)
  stnn (Lit prevBankAddr)
  -- switch to target bank
  bankSlot1 bank
  -- call target
  call (LabelRef target)
  -- restore previous bank
  ldAnn (Lit prevBankAddr)
  stnn (Lit regSlot1)
```

---

## ROM Builder Changes

The current `assemble` function produces a single `ByteString` ≤32 KB.  For multi-bank ROMs,
the builder needs:

1. A way to mark the **start of a new bank** (`bankStart :: Word8 -> Asm ()` emits an `ORG`
   to `0x0000` with a bank annotation).
2. Padding each bank to exactly 16 KB (`0x4000` bytes) before appending the next.
3. A `ROMConfig` field for the total number of banks (used in the Game Gear header's size byte).

```haskell
data ROMConfig = ROMConfig
  { ...
  , romBanks :: Word8   -- total number of 16 KB banks (1, 2, 4, 8, 16, 32)
  }

-- | Mark the start of a new 16 KB bank.
-- Subsequent code/data is assembled into that bank's address space (0x0000–0x3FFF).
bankStart :: Word8 -> Asm ()
bankStart _bankNum = org 0x0000   -- reset origin; builder tracks bank boundaries
```

---

## Usage Example: Loading Level Tiles from Bank 2

```haskell
-- In bank 0:
loadLevelTiles <- defineLabel "loadLevelTiles"
-- (called by main loop when entering level 2)

bankSlot1 2           -- switch slot 1 to bank 2
ld16 HL (LabelRef levelTileData)   -- data is at 0x4000 in bank 2
-- ... bulk copy to VRAM using OTIR ...
bankSlot1 1           -- restore default
ret

-- In bank 2:
org 0x4000
levelTileData <- defineLabel "levelTileData"
loadTiles 0 levelTiles
```

---

## Notes

- **Slot 0 is dangerous to switch**: The reset vector, interrupt vectors, and currently
  executing code all live in slot 0.  Switching slot 0 mid-execution crashes the CPU.  Leave
  `0xFFFD` = 0 permanently.
- **Stack is in RAM**: The stack at `0xDFFF` is always accessible regardless of bank state —
  it's in system RAM, not ROM.
- **ROM header size byte**: The GG header at `0x7FF0` includes a size field.  With bank
  switching, this must reflect the total ROM size.  See `ROM/GameGear.hs`.
- **Emulator support**: Emulicious and most other GG emulators support the Sega mapper
  automatically when the ROM header is correctly populated.
