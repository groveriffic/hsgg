# Input on the Game Gear

## Overview

The Game Gear has five built-in inputs accessible through two I/O ports:

- **D-pad** (up, down, left, right) and **buttons 1 & 2** via port `0xDC`
- **Start button** via port `0x00`

All inputs are **active low**: the bit reads `0` when the button is pressed and `1` when released.
Reading is instantaneous — no handshake or interrupt is required.

---

## Hardware Ports

### Port 0xDC — Controller Data

| Bit | Button   |
|-----|----------|
|  0  | Up       |
|  1  | Down     |
|  2  | Left     |
|  3  | Right    |
|  4  | Button 1 (left trigger / A) |
|  5  | Button 2 (right trigger / B) |
| 6:7 | Unused (always 1) |

Read with `IN A, (0xDC)`.  Invert (`CPL` or `XOR 0x3F`) to get 1 = pressed.

### Port 0x00 — Start Button

| Bit | Meaning |
|-----|---------|
|  7  | Start (0 = pressed) |
| 6:0 | Unrelated hardware flags |

Read with `IN A, (0x00)`, then test bit 7: `BIT 7, A` sets the Z flag when Start is pressed.

---

## Polling vs. Edge Detection

**Raw polling** tells you the current state of every button:

```
IN A, (0xDC)
CPL              ; invert: 1 = pressed
AND 0x3F         ; mask to bits 5:0
```

**Edge detection** tells you which buttons were *just* pressed this frame (avoids
repeated triggers when a button is held).  Requires a one-byte RAM variable `prevInput`.

```
current = ~IN(0xDC) & 0x3F
justPressed = current & ~prevInput
prevInput = current
```

Debouncing is generally unnecessary on the GG's digital inputs — contact bounce is filtered
by the hardware.  If needed for reliability, require the same state for two consecutive frames.

---

## Suggested DSL Abstraction

```haskell
portController :: Word8
portController = 0xDC

portStartBtn :: Word8
portStartBtn = 0x00

-- | Bit masks for controller port (after inverting)
btnUp, btnDown, btnLeft, btnRight, btnA, btnB :: Word8
btnUp    = 0x01
btnDown  = 0x02
btnLeft  = 0x04
btnRight = 0x08
btnA     = 0x10
btnB     = 0x20

-- | Read the controller into A (1 = pressed, active high).
-- Destroys A.
readController :: Asm ()
readController = do
  inA portController
  cpl              -- invert: 1 = pressed
  andAn 0x3F       -- mask to 6 buttons

-- | Read and combine Start into the high bit of A alongside controller bits.
-- Bit 7 of result = Start.  Destroys A, B.
readAllButtons :: Asm ()
readAllButtons = do
  readController       -- A = D-pad + AB (bits 5:0)
  push AF
  inA portStartBtn     -- A = port 0x00
  rlca; rlca           -- rotate Start (bit 7) down to bit 6 ... (adjust as needed)
  andAn 0x40           -- isolate bit 6
  ld B A
  pop AF
  orA B                -- merge Start into A

-- | Emit edge-detection logic.
-- Reads controller, computes just-pressed bits vs. previous state stored at @prevAddr@.
-- On return: A = just-pressed mask (1 = newly pressed this frame).
-- Destroys A, B.
readJustPressed :: Word16 -> Asm ()
readJustPressed prevAddr = do
  readController        -- A = current (1 = pressed)
  ld B A                -- B = current
  ldAnn (Lit prevAddr)  -- A = previous
  cpl                   -- A = ~previous
  andA B                -- A = current & ~previous = just pressed
  ld A B
  stnn (Lit prevAddr)   -- prevInput = current
```

---

## Usage Examples

### Check If Right Is Held

```haskell
-- Assumes A already contains readController result
readController
andAn btnRight
jp_cc Z noMove    -- Z set means button not pressed
-- ... move right
```

### Directional Movement in a Game Loop

```haskell
-- RAM: ramPrevInput at 0xC001

readController           -- A = current inputs
ld B A                   -- save current

-- Horizontal
andAn (btnLeft .|. btnRight)
jp_cc Z noHoriz

ld A B
andAn btnRight
jp_cc Z checkLeft
-- move right ...
checkLeft <- defineLabel "checkLeft"
ld A B
andAn btnLeft
jp_cc Z noHoriz
-- move left ...
noHoriz <- defineLabel "noHoriz"

-- Jump on just-pressed A button
readJustPressed 0xC001
andAn btnA
jp_cc Z noJump
-- jump ...
noJump <- defineLabel "noJump"
```

### Pause on Start

```haskell
inA portStartBtn
bit 7 A
jp_cc NZ gameLoop   -- bit7=1 means NOT pressed
-- pause screen ...
```

---

## Notes

- Port `0xDC` bits 6–7 are tied high; mask to `0x3F` before using.
- On original hardware, port `0xDC` returns `0xFF` if read with no cartridge inserted.
- The two action buttons are unlabeled on some GG revisions; convention is Button 1 = left
  (A face), Button 2 = right (B face).
- There is no analog input; all buttons are strictly digital.
