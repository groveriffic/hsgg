# Game Architecture

## Overview

A complete game needs more than raw hardware access.  Four interacting systems underpin most
Game Gear titles:

1. **Scene / State Machine** — switches between title screen, gameplay, pause, game over
2. **Entity Management** — per-object position, velocity, animation state in RAM tables
3. **Frame Loop** — structured update/render phases synchronised to VBlank
4. **Timer / Counter Infrastructure** — frame counters, cooldown timers, animation clocks

None of these require new hardware features; they are patterns over RAM, the existing VDP
helpers, and the `Asm` monad.

---

## RAM Layout

On the Game Gear, general-purpose RAM occupies `0xC000–0xDFFF` (8 KB).  Stack grows down
from `0xDFFF`.

Suggested layout (adjust sizes to fit):

```
0xC000  ramGameState      1 byte   (scene / state machine)
0xC001  ramFrameReady     1 byte   (ISR → main-loop signal)
0xC002  ramFrameCounter   2 bytes  (running frame count, lo/hi)
0xC004  ramScrollX        1 byte
0xC005  ramScrollY        1 byte
0xC010  ramPlayerX        2 bytes  (world space, 16-bit)
0xC012  ramPlayerY        2 bytes
0xC014  ramPlayerVX       1 byte   (signed velocity)
0xC015  ramPlayerVY       1 byte
0xC016  ramPlayerAnim     1 byte   (animation frame + counter)
0xC020  ramEntityTable   64 bytes  (8 entities × 8 bytes each — see below)
...
0xDFFF  (stack top)
```

---

## Scene / State Machine

### State Constants

```haskell
stateTitle    :: Word8; stateTitle    = 0x00
stateGameplay :: Word8; stateGameplay = 0x01
statePause    :: Word8; statePause    = 0x02
stateGameOver :: Word8; stateGameOver = 0x03
```

### Dispatch Pattern

The state machine is a jump table: read the state byte, multiply by 2 (each entry is a 2-byte
address), look up the handler address from a table in ROM, and jump to it.

```haskell
-- | Emit a state dispatch using a jump table.
-- State byte is read from @stateAddr@; the table at @tableLabel@ holds one
-- 16-bit handler address per state (little-endian).
-- Destroys A, HL.
dispatchState :: Word16 -> Label -> Asm ()
dispatchState stateAddr tableLabel = do
  ldAnn (Lit stateAddr)
  addA A                        -- A *= 2 (index into word table)
  ld16 HL (LabelRef tableLabel)
  addHL HL                      -- advance HL by index (simplified; see note)
  -- HL now points to handler address; load and jump
  ldHL A                        -- low byte
  inc16 HL
  ld B A                        -- save low
  ldHL A                        -- high byte
  ld H A
  ld L B
  jpHL
```

### Jump Table in ROM

```haskell
sceneTable <- defineLabel "sceneTable"
dw [LabelRef titleScene, LabelRef gameplayScene,
    LabelRef pauseScene, LabelRef gameOverScene]
```

---

## Entity Management

### Entity Layout (8 bytes per entity)

```
Offset  Size  Field
  0      1    state (0 = inactive)
  1      2    worldX (little-endian)
  3      2    worldY (little-endian)
  5      1    velX   (signed)
  6      1    velY   (signed)
  7      1    animFrame
```

### Entity Table Access (IX-indexed)

The Z80's IX register is ideal for struct access: load the entity base address into IX, then
use `LD r, (IX+offset)` / `LD (IX+offset), r` for each field.

```haskell
-- Entity field offsets
entState  :: Int8; entState  = 0
entX      :: Int8; entX      = 1   -- 16-bit; entX+1 = high byte
entY      :: Int8; entY      = 3
entVelX   :: Int8; entVelX   = 5
entVelY   :: Int8; entVelY   = 6
entAnim   :: Int8; entAnim   = 7
entSize   :: Word16; entSize = 8

-- | Load entity @idx@ base address into IX.
-- Destroys A, IX.
loadEntityIX :: Word8 -> Asm ()
loadEntityIX idx = do
  ld16n IX (ramEntityTable + fromIntegral idx * fromIntegral entSize)

-- | Update entity position from velocity (in-place via IX).
-- Destroys A.
applyVelocity :: Asm ()
applyVelocity = do
  ldIX A entX
  addA A (ldIX A entVelX >> pure ())  -- simplified; real version loads and adds
  stIX entX A
  ldIX A entY
  -- ... similar for Y
```

### Entity Loop Pattern

```haskell
-- | Emit a loop over all @count@ entity slots.
-- For each slot, IX points to the entity base; body is emitted for each.
-- Destroys B, IX.
forEntities :: Word8 -> Asm () -> Asm ()
forEntities count body = do
  ld16n IX ramEntityTable
  ldi B count
  loopLbl <- freshLabel "_entLoop"
  rawLabel loopLbl
  body
  -- advance IX by entSize
  ld16n DE (fromIntegral entSize)
  addIX DE
  djnz (LabelRef loopLbl)
```

---

## Frame Loop

### Structure

```
┌─ VBlank ISR ────────────────────┐
│ 1. Update VDP (scroll, SAT)     │  ← ~160 µs VBlank window
│ 2. Set ramFrameReady = 1        │
└─────────────────────────────────┘
           ↓
┌─ Main loop ─────────────────────┐
│ 1. Wait for ramFrameReady       │  ← spin or sleep
│ 2. Clear ramFrameReady          │
│ 3. Increment frame counter      │
│ 4. Read input                   │
│ 5. Update game state            │
│ 6. Update entities              │
│ 7. Prepare VDP shadow buffers   │  ← write to RAM, not VDP directly
└─────────────────────────────────┘
```

Writing VDP state (scroll regs, SAT) to RAM shadow buffers during the main loop and flushing
them in the ISR keeps VDP updates atomic and avoids flickering.

### Suggested Implementation

```haskell
-- | Emit the standard frame loop prologue.
-- Waits for ramFrameReady, clears it, and increments the 16-bit frame counter.
-- Destroys A, HL.
frameSync :: Asm ()
frameSync = do
  waitLbl <- freshLabel "_frameWait"
  rawLabel waitLbl
  ldAnn (Lit ramFrameReady)
  cpAn 0
  jr_cc Z (LabelRef waitLbl)
  xorA A
  stnn (Lit ramFrameReady)
  -- increment 16-bit frame counter
  ldHLind (Lit ramFrameCounter)
  inc16 HL
  stHLaddr (Lit ramFrameCounter)
```

---

## Timer / Counter Infrastructure

### Frame-Based Timers

A timer is a RAM byte (or word) that counts down to zero:

```haskell
-- | Decrement a one-byte timer at @addr@.  Z flag is set when it reaches 0.
-- Does NOT reload — caller must reset if needed.  Destroys A.
tickTimer :: Word16 -> Asm ()
tickTimer addr = do
  ldAnn (Lit addr)
  cpAn 0
  jp_cc Z skip        -- already zero, don't underflow
  dec A
  stnn (Lit addr)
  cpAn 0              -- set Z if now zero
  skip <- freshLabel "_timerSkip"
  rawLabel skip
```

### Animation Clock Pattern

An animation frame changes every N game frames.  Store `(animFrame, animClock)` together in
one RAM word.

```haskell
-- | Advance animation: decrement clock; when it hits 0, advance frame and reload.
-- @addr@ = animation byte, @period@ = frames per animation step,
-- @frameCount@ = number of animation frames (wraps).
-- Destroys A.
tickAnimation :: Word16 -> Word8 -> Word8 -> Asm ()
tickAnimation clockAddr period frameCount = do
  ldAnn (Lit clockAddr)
  dec A
  jp_cc NZ (ref "_animDone")
  ldi A period            -- reload clock
  stnn (Lit clockAddr)
  ldAnn (Lit (clockAddr + 1))  -- advance frame
  inc A
  cpAn frameCount
  jp_cc NZ (ref "_animNoWrap")
  xorA A
  rawLabel (Label "_animNoWrap")
  stnn (Lit (clockAddr + 1))
  rawLabel (Label "_animDone")
```

---

## Usage Example: Full Game Loop Skeleton

```haskell
assemble defaultROMConfig $ do
  org 0x0000
  di
  ld16n SP 0xDFFF       -- initialise stack

  -- zero RAM
  ld16n HL 0xC000
  ld16n BC 0x2000
  xorA A
  ldi C portVDPData     -- reuse C (harmless before VDP init)
  -- actually use LDIR to zero:
  -- ld16n DE 0xC001; ldi A 0; stnn (Lit 0xC000); ldir_

  vdpInit
  -- load tiles, palette ...
  enableDisplay

  -- Set initial scene
  ldi A stateTitle
  stnn (Lit ramGameState)

  im1
  ei

  gameLoop <- defineLabel "gameLoop"
  frameSync            -- wait for VBlank ISR signal

  -- Dispatch to current scene handler
  ldAnn (Lit ramGameState)
  cpAn stateTitle
  jp_cc Z (ref "titleScene")
  cpAn stateGameplay
  jp_cc Z (ref "gameplayScene")
  jp (LabelRef gameLoop)

  titleScene <- defineLabel "titleScene"
  -- ... handle title screen input, transition to gameplay
  jp (LabelRef gameLoop)

  gameplayScene <- defineLabel "gameplayScene"
  -- read input, update player, update entities, update scroll shadow regs
  jp (LabelRef gameLoop)
```

---

## Notes

- **Shadow buffers**: Never write scroll registers or SAT entries directly from the main loop.
  Write to RAM copies; flush them in the VBlank ISR.  This ensures the VDP always sees a
  consistent frame.
- **Stack discipline**: SP = `0xDFFF` at startup; each PUSH/CALL consumes 2 bytes.  A typical
  game uses 64–128 bytes of stack.  Avoid deep recursion.
- **Entity tables**: Keep entity count small (8–16).  The GG VDP supports 64 hardware sprites,
  but updating 64 SAT entries per frame consumes a significant portion of VBlank time.
