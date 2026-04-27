# Collision Detection

## Overview

Collision detection on the Game Gear falls into two categories:

1. **AABB (Axis-Aligned Bounding Box)** — entity vs. entity; checks rectangle overlap in
   world space.
2. **Tile collision** — entity vs. background map; samples corner pixels against a per-tile
   collision flag.

Both operate on world-space coordinates (see `Scrolling.md`) and are computed during the
update phase of the frame loop.

---

## AABB Collision

Two rectangles overlap if and only if they overlap on **both** axes.  They do *not* overlap if
any of the following is true:

```
ax + aw ≤ bx   (A is left of B)
bx + bw ≤ ax   (B is left of A)
ay + ah ≤ by   (A is above B)
by + bh ≤ ay   (B is above A)
```

For 8-bit world coordinates (0–255), all operands are unsigned bytes.  The check fits in the
Z80's comparison instructions.

### Z80 Implementation

```z80
; Inputs: A=ax, B=bx, C=bw, D=ay, E=by  (plus bh, aw, ah from RAM / registers)
; Returns: Z flag set if NO collision, NZ if collision

; Check ax + aw > bx  (i.e. left edge of B < right edge of A)
add a, aw       ; A = ax + aw
cp b            ; A - bx
jr c, noCollide ; carry = ax+aw < bx, no overlap on X

; Check bx + bw > ax
ld a, b         ; A = bx
add a, c        ; A = bx + bw
cp ax           ; compare against ax
jr c, noCollide

; Check ay + ah > by  (similar for Y)
...

; If we reach here: collision
```

### Suggested Abstraction

```haskell
-- | AABB descriptor stored in ROM or RAM.
data AABB = AABB
  { aabbW :: Word8   -- width  (in pixels)
  , aabbH :: Word8   -- height
  , aabbOX :: Int8   -- X offset from entity origin
  , aabbOY :: Int8   -- Y offset from entity origin
  }

-- | Emit AABB overlap test between two entities.
-- IX = entity A base, IY = entity B base.
-- Sets Z flag if NO collision; NZ if collision.
-- Registers used: A, B, C, D, E.
--
-- Entity layout assumed (from GameArchitecture.md):
--   entX = IX+1 (low byte), entY = IX+3 (low byte)
--
-- Width/height must be passed as compile-time constants @aw@, @ah@, @bw@, @bh@.
checkAABB :: Word8 -> Word8 -> Word8 -> Word8 -> Asm ()
checkAABB aw ah bw bh = do
  noCollide <- freshLabel "_noCollide"

  -- X axis: ax + aw > bx
  ldIX A entX
  addAn aw
  ldIY B entX
  cpA B
  jr_cc NC noCollide    -- ax + aw <= bx: no X overlap

  -- bx + bw > ax
  ldIY A entX
  addAn bw
  ldIX B entX
  cpA B
  jr_cc NC noCollide    -- bx + bw <= ax: no X overlap

  -- Y axis: ay + ah > by
  ldIX A entY
  addAn ah
  ldIY B entY
  cpA B
  jr_cc NC noCollide

  -- by + bh > ay
  ldIY A entY
  addAn bh
  ldIX B entY
  cpA B
  jr_cc NC noCollide

  -- NZ = collision
  orAn 1              -- ensure NZ
  jp (ref "_collideEnd")

  rawLabel noCollide
  xorA A              -- Z = no collision

  rawLabel (Label "_collideEnd")
```

---

## Tile Collision

Tile collision checks whether an entity overlaps a solid tile in the background name table.
The usual approach is **corner sampling**: test the four corner pixels of the entity's bounding
box against the tile they land on.

### Tile Solidity

Tiles are divided into solid and passable by tile index.  The simplest scheme: any tile index
≥ a threshold is solid.  More flexible: a 32-byte bitmask in ROM where bit `tileIdx % 8` of
byte `tileIdx / 8` is 1 if solid.

```haskell
-- | Check if tile at world position (wx, wy) is solid.
-- @solidThreshold@: tiles with index >= this are solid.
-- Returns: A = tile index; Z flag set if NOT solid (passable).
-- Destroys A, HL, DE.
isTileSolid :: Word16 -> Word8 -> Asm ()
isTileSolid solidThreshold worldX_in_A = do
  -- Convert world pixel coords to tile coords
  -- tileCol = worldX / 8,  tileRow = worldY / 8
  -- Use the values passed in registers (caller loads worldX into A, worldY into B)
  rra; rra; rra         -- A = worldX / 8 (tileCol), bits 4:0
  andAn 0x1F            -- mask to 0-31
  ld C A                -- C = tileCol

  ld A B
  rra; rra; rra
  andAn 0x1F            -- A = tileRow (0-27)
  ld D A                -- D = tileRow

  -- VRAM address = nameTableBase + (tileRow * 32 + tileCol) * 2
  -- = 0x3800 + (D * 32 + C) * 2
  -- Compute using HL arithmetic:
  ld16n HL nameTableBase
  -- add tileRow * 64 (= tileRow * 32 * 2)
  xorA A; ld A D
  addA A; addA A; addA A; addA A; addA A; addA A  -- A = tileRow * 64
  ld E A; ld D 0
  addHL DE

  -- add tileCol * 2
  xorA A; ld A C
  addA A                -- A = tileCol * 2
  ld E A; ld D 0
  addHL DE

  -- HL = name table VRAM address for this tile; read it
  setVRAMAddr HL_as_Word16_placeholder
  inA portVDPData       -- A = low byte of name table entry (tile index low 8 bits)
  cpAn solidThreshold
  -- Z set if A < solidThreshold (passable), NZ if solid
```

> **Implementation note**: Reading from VRAM requires setting the VDP to read mode (`0x00 |
> addr high`) and then reading from port `0xBE`.  This stalls the CPU for one byte.  Tile
> collision via VRAM reads is slow; a RAM mirror of the name table is faster.

### RAM Mirror Approach (Recommended)

Maintain a copy of the name table tile indices in RAM (32×28 = 896 bytes at e.g. `0xC200`).
Update the RAM copy whenever tiles change.  Tile lookup becomes a simple RAM read:

```
addr = ramTileMap + tileRow * 32 + tileCol
tile = RAM[addr]
solid = tile >= solidThreshold
```

```haskell
ramTileMap :: Word16
ramTileMap = 0xC200   -- 896 bytes

-- | Read tile index at (tileCol, tileRow) from RAM mirror.
-- tileCol in C (0-31), tileRow in D (0-27).
-- Returns A = tile index.  Destroys A, HL, DE.
readTileFromRAM :: Asm ()
readTileFromRAM = do
  ld16n HL ramTileMap
  ld A D; addA A; addA A; addA A; addA A; addA A  -- A = row * 32
  ld E A; ld D 0; addHL DE
  ld A C; ld E A; ld D 0; addHL DE
  ldHL A
```

---

## Collision Response

After detecting a collision, the game must respond: stop movement, bounce, deal damage, etc.
The response depends on the axis — a platformer stops vertical movement on floor collision
but allows horizontal movement to continue.

### Separating Axis Response

For entity-vs-tile platformers, check each axis independently:

```
1. Move entity by velX only.  If solid tile: undo X movement, zero velX.
2. Move entity by velY only.  If solid tile: undo Y movement, zero velY.
   If velY was downward, set "on ground" flag.
```

This prevents diagonal "corner catching" where both axes would block movement.

---

## Usage Example: Player vs. Enemy

```haskell
-- Check collision between player (IX) and enemy[0] (IY).
-- Player AABB: 12×14 px.  Enemy AABB: 10×12 px.

ld16n IX ramPlayerBase
ld16n IY ramEntityTable     -- entity 0

checkAABB 12 14 10 12       -- emits overlap test; NZ = collision
jp_cc Z noHit               -- Z = no collision

-- handle hit: decrease player health
ldAnn (Lit ramPlayerHP)
dec A
stnn (Lit ramPlayerHP)

noHit <- defineLabel "noHit"
```

---

## Notes

- **16-bit world coordinates**: If world space exceeds 256 pixels, use 16-bit position values.
  The overlap check then operates on the high bytes (pixel-precise to ±1 tile) or uses 16-bit
  subtraction and sign checks.
- **Scanline collision**: Some GG games detect sprite-vs-sprite hits using the VDP's sprite
  overflow/collision status bit (VDP status bit 5).  This is approximate (any two sprites share
  a pixel) and fires at most once per frame — use it only as a coarse trigger.
- **Tile collision on slopes**: Not covered here.  Slope collision requires either sub-tile
  pixel masks or a dedicated slope table mapping tile index to a function of X offset to height.
