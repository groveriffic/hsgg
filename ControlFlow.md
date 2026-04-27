# Control Flow DSL

## Overview

The `Asm` monad assembles Z80 instructions in-order, so all branching is expressed using
labels and jump instructions (`JP`, `JR`, `DJNZ`, etc.).  This is correct but verbose: a
simple if-statement requires allocating two labels, emitting the conditional jump, then
placing the end-label after the else block.

A thin layer of higher-order combinators over `freshLabel` and `jp_cc` / `jr_cc` eliminates
the boilerplate while staying 100% transparent — the emitted machine code is identical to what
you would write by hand.

---

## Primitives (already in the DSL)

| Combinator | Z80 encoding | Notes |
|---|---|---|
| `jp (LabelRef l)` | `JP nn` | 3 bytes, any distance |
| `jp_cc cond (LabelRef l)` | `JP cc, nn` | 3 bytes, any distance |
| `jr (LabelRef l)` | `JR e` | 2 bytes, ±127 bytes only |
| `jr_cc cond (LabelRef l)` | `JR cc, e` | 2 bytes, ±127 bytes only |
| `djnz (LabelRef l)` | `DJNZ e` | B--, jump if B≠0 |
| `call (LabelRef l)` | `CALL nn` | pushes return address |
| `ret` | `RET` | returns from subroutine |

---

## Suggested Combinators

### `ifAsm` — conditional block

```haskell
-- | Emit a conditional block.  @cond@ is the condition that must hold
-- for the body to execute (i.e. the jump is taken when the condition is FALSE).
--
-- The caller must set flags before calling ifAsm.
-- Example: cpAn 5 >> ifAsm Z body  runs body only when A == 5.
ifAsm :: Condition -> Asm () -> Asm ()
ifAsm cond body = do
  endLbl <- freshLabel "_ifEnd"
  jp_cc (invertCond cond) (LabelRef endLbl)
  body
  rawLabel endLbl
```

### `ifElseAsm` — if / else

```haskell
ifElseAsm :: Condition -> Asm () -> Asm () -> Asm ()
ifElseAsm cond thenBody elseBody = do
  elseLbl <- freshLabel "_else"
  endLbl  <- freshLabel "_ifEnd"
  jp_cc (invertCond cond) (LabelRef elseLbl)
  thenBody
  jp (LabelRef endLbl)
  rawLabel elseLbl
  elseBody
  rawLabel endLbl
```

### `whileAsm` — condition checked at top

```haskell
-- | Loop while the flags satisfy @cond@.
-- The condition expression (flag-setting code) is re-evaluated each iteration.
--
-- Example: whileAsm NZ (cpAn 0) body  loops while A ≠ 0 (cpAn sets flags).
whileAsm :: Condition -> Asm () -> Asm () -> Asm ()
whileAsm cond condExpr body = do
  topLbl <- freshLabel "_whileTop"
  endLbl <- freshLabel "_whileEnd"
  rawLabel topLbl
  condExpr
  jp_cc (invertCond cond) (LabelRef endLbl)
  body
  jp (LabelRef topLbl)
  rawLabel endLbl
```

### `doWhileAsm` — condition checked at bottom

```haskell
doWhileAsm :: Condition -> Asm () -> Asm () -> Asm ()
doWhileAsm cond body condExpr = do
  topLbl <- freshLabel "_doTop"
  rawLabel topLbl
  body
  condExpr
  jp_cc cond (LabelRef topLbl)
```

### `forAsm` — counted loop (uses B register)

```haskell
-- | Emit a counted loop using the Z80 DJNZ instruction.
-- B is set to @count@ before the loop; body runs @count@ times.
-- Destroys B.
forAsm :: Word8 -> Asm () -> Asm ()
forAsm count body = do
  lbl <- freshLabel "_forLoop"
  ldi B count
  rawLabel lbl
  body
  djnz (LabelRef lbl)
```

### `invertCond` — helper

```haskell
invertCond :: Condition -> Condition
invertCond NZ = Z;  invertCond Z  = NZ
invertCond NC = CF; invertCond CF = NC
invertCond PO = PE; invertCond PE = PO
invertCond P  = M;  invertCond M  = P
```

---

## Usage Examples

### If: branch on button press

```haskell
readController
andAn btnA
ifAsm NZ $ do          -- execute when NZ (A button is pressed)
  -- handle jump
  ldi A 10
  stnn (Lit ramJumpVel)
```

### If/Else: game state check

```haskell
ldAnn (Lit ramGameState)
cpAn stateGameplay
ifElseAsm Z
  (do -- gameplay branch
      updatePlayer
      updateEntities)
  (do -- other states: title, pause, etc.
      updateMenu)
```

### While: wait for VBlank (alternative form)

```haskell
-- Equivalent to the existing waitVBlank but using the combinator
whileAsm Z
  (inA portVDPCtrl >> bit 7 A)  -- condition: Z set when flag NOT set yet
  (pure ())                      -- empty body — the condition IS the work
```

### For: copy N bytes

```haskell
-- Copy 8 bytes from HL to DE
forAsm 8 $ do
  ldHL A
  stDE
  inc16 HL
  inc16 DE
```

### Nested: counted loop with conditional break

```haskell
-- Scan entity table; stop at first inactive slot (state byte == 0)
ld16n HL 0xC100   -- entity table base
forAsm 16 $ do
  ldHL A
  cpAn 0
  ifAsm Z $ do
    -- found free slot; set it up
    stHLn entityStateActive
```

---

## Notes

- **Jump distance**: `jp` (3-byte absolute) works at any distance; prefer it inside combinators
  to avoid linker errors on large bodies.  `jr` (2-byte relative) saves one byte but is limited
  to ±127 bytes — safe only for tight inner loops.
- **Register discipline**: The combinators themselves only use `freshLabel` and jumps — they do
  not touch any registers.  Document register usage in the caller.
- **Inline vs. subroutine**: These combinators emit the body inline.  For code shared across
  multiple call sites, define it as a `call`/`ret` subroutine instead and call it from within
  a combinator body.
