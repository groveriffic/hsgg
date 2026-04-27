# Static Analysis

## Overview

Two static analysis capabilities are on the roadmap:

1. **Timing analysis** — count Z80 T-states for routines; verify they fit within VBlank or
   per-scanline budgets.
2. **Emulation tests** — assemble a ROM, run it in Emulicious, assert on memory/register state
   (partially implemented; screenshot assertions are still TODO).

---

## T-State Counting

### Z80 Cycle Reference

Each Z80 instruction takes a fixed number of T-states (clock cycles).  At the Game Gear's
3.579545 MHz, one T-state ≈ 0.279 µs.

Key instruction costs:

| Instruction | T-states |
|-------------|----------|
| NOP | 4 |
| LD r, r' | 4 |
| LD r, n | 7 |
| LD r, (HL) | 7 |
| LD r, (IX+d) | 19 |
| LD (nn), A | 13 |
| LD A, (nn) | 13 |
| ADD A, r | 4 |
| ADD A, n | 7 |
| JP nn | 10 |
| JP cc, nn (taken) | 10 |
| JP cc, nn (not taken) | 10 |
| JR e (taken) | 12 |
| JR e (not taken) | 7 |
| DJNZ e (taken) | 13 |
| DJNZ e (not taken) | 8 |
| CALL nn | 17 |
| RET | 10 |
| PUSH rr | 11 |
| POP rr | 10 |
| IN A, (n) | 11 |
| OUT (n), A | 11 |
| OTIR (per byte) | 21 (last: 16) |

### Timing Budgets

| Period | Scanlines | T-states (approx) | Time (µs) |
|--------|-----------|-------------------|-----------|
| Full frame (50 Hz / PAL) | 262 | 59,659 | 16,666 |
| Full frame (60 Hz / NTSC) | 262 | 59,659 | 16,666 |
| Active display (144 lines) | 144 | 32,832 | 9,175 |
| VBlank window | ~28 lines | ~6,384 | ~1,784 |
| One scanline | 1 | 228 | 63.7 |

> The GG runs at 60 fps with 262 total scanlines (144 active + 18 bottom border + ~28 VBlank +
> top border).  The exact VBlank window varies slightly by revision; ~28 scanlines × 228
> T-states = ~6,384 T-states is a safe conservative budget.

### Approach: T-State Annotation in the AST

Each `Instruction` constructor has a known T-state count.  A `countTStates :: Seq Statement ->
Int` pass over the assembled statements yields the cycle cost of a region.

```haskell
-- | T-state cost of a single instruction (worst-case / taken branch).
tStates :: Instruction -> Int
tStates NOP          = 4
tStates (LD_r_r _ _) = 4
tStates (LD_r_n _ _) = 7
tStates (LD_r_HL _)  = 7
tStates (LD_r_IXd _ _) = 19
tStates (LD_r_IYd _ _) = 19
tStates (LD_nn_A _)  = 13
tStates (LD_A_nn _)  = 13
tStates (OUT_n_A _)  = 11
tStates (IN_A_n _)   = 11
tStates (JP _)       = 10
tStates (JP_cc _ _)  = 10   -- taken; not-taken = 10 (same for JP)
tStates (JR _)       = 12
tStates (JR_cc _ _)  = 12   -- taken; not-taken = 7
tStates (CALL _)     = 17
tStates RET          = 10
tStates (PUSH_rr _)  = 11
tStates (POP_rr _)   = 10
tStates DJNZ _       = 13   -- taken; not-taken = 8
tStates OTIR         = 21   -- per byte (last byte = 16)
-- ... (complete table)
tStates _            = 4    -- conservative fallback

-- | Sum T-states for a flat sequence of instructions (no loop unrolling).
countTStates :: Seq Statement -> Int
countTStates = sum . map stateTStates . toList
  where
    stateTStates (Instr i) = tStates i
    stateTStates _         = 0

-- | Assert that @action@ fits within @budget@ T-states at compile time.
-- Throws an error at assembly time if the budget is exceeded.
withinBudget :: Int -> Asm () -> Asm ()
withinBudget budget action = do
  let stmts = runAsm action
      cost  = countTStates stmts
  when (cost > budget) $
    error ("T-state budget exceeded: " ++ show cost ++ " > " ++ show budget)
  -- emit the statements
  mapM_ (append) stmts  -- re-insert into the outer Asm context
```

### Usage: VBlank Budget Check

```haskell
-- Verify that the VBlank ISR body fits in 6,000 T-states (conservative).
withinBudget 6000 $ do
  isrEnter            -- ~44 T-states (4 pushes × 11)
  ackVDPInterrupt     -- 11 T-states
  -- update 4 sprites (approx 200 T-states each)
  updateCompositeSprite2x2 0 playerScreenX playerScreenY
  -- update scroll registers
  ldAnn (Lit ramScrollX); vdpWriteRegA 8
  ldAnn (Lit ramScrollY); vdpWriteRegA 9
  isrLeave            -- ~51 T-states (4 pops × 10 + EI 4 + RETI 14)
```

---

## Emulation Tests

The existing test infrastructure (`test/Emulicious/`) already covers:

- [x] Assemble a ROM
- [x] Launch Emulicious via Docker + DAP
- [x] Run until `HALT`
- [x] Assert RAM byte values (`assertRAM`)
- [x] Assert RAM byte ranges (`assertRAMRange`)

### Remaining: Screenshot Assertions

To assert on screen output (pixel-accurate rendering tests), the test runner needs to capture
a screenshot from Emulicious and compare it against a reference image.

Emulicious supports screenshot capture via DAP custom commands or by writing to a special
register — the exact mechanism needs research.

```haskell
-- Proposed API (not yet implemented):
assertScreenshot :: FilePath -> Test ()
assertScreenshot refPath = do
  actualPng <- captureScreenshot   -- new DAP helper
  expected  <- readPng refPath
  assertEqual "screenshot mismatch" expected actualPng

-- Or: pixel-level comparison with tolerance
assertPixel :: Int -> Int -> GGColor -> Test ()
assertPixel x y expectedColor = do
  actual <- readPixel x y
  assertEqual ("pixel (" ++ show x ++ "," ++ show y ++ ")") expectedColor actual
```

Screenshot tests are especially valuable for:
- Verifying tile rendering and palette application
- Regression-testing raster effects (wavy water must waver at the right scanline)
- Checking that scrolling moves the viewport correctly

---

## T-State Test Pattern

A ROM-level timing test uses the emulator's register state to measure elapsed cycles:

```haskell
-- Assemble a ROM that:
--   1. Captures the R register (increments every 2 T-states) before the routine
--   2. Runs the routine
--   3. Captures R after, stores the delta in RAM
--   4. HALTs

-- Then in the test:
timing_test :: Test ()
timing_test = do
  result <- runROM timingROM
  delta  <- assertRAM 0xC000       -- R-register delta stored here
  assertBool ("routine too slow: " ++ show delta) (delta <= 100)
```

The Z80 R register increments by 1 for each non-prefixed instruction fetch and by 2 for
`ED`/`DD`/`FD`-prefixed instructions.  It approximates cycle count but is not exact; for
precision, count T-states statically.

---

## Notes

- **OTIR cost**: Each byte costs 21 T-states (B≠0) or 16 T-states (last byte, B=0 after
  decrement).  For an OTIR loop copying N bytes: `(N-1)*21 + 16` T-states.
- **Conditional branches**: Use worst-case (taken) counts for budget analysis.  If a branch
  is almost never taken, annotate with `-- [rarely taken]` and use the not-taken count.
- **Interrupt latency**: When interrupts are enabled, add a worst-case 20 T-states for the
  ISR acknowledge and jump overhead to any code that can be interrupted.
- **Static vs. dynamic**: T-state counting is static and cannot model loop iteration counts.
  For loops with a known bound, unroll the analysis manually.  For dynamic routines, use the
  emulator's built-in cycle counter (Emulicious exposes cycle counts via DAP).
