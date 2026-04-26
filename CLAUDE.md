# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**hsgg** is a Haskell-based Z80 assembler DSL targeting the Sega Game Gear. It provides a type-safe embedded DSL for writing Game Gear ROMs in Haskell, with a complete pipeline: Haskell `Asm` monad code → Z80 instructions → `.gg` ROM file.

## Build & Test Commands

```bash
# Build
stack build

# Build and run demo (generates demo.gg)
stack build && stack exec hsgg-exe

# Run all tests (requires Emulicious at ~/Emulicious/Emulicious.jar)
stack test

# Run a single test by name
stack test --test-arguments="--match 'RAM writes'"
```

Tests require Java and the Emulicious emulator JAR at `~/Emulicious/Emulicious.jar`.

## Architecture

The compiler pipeline has four stages:

```
Haskell DSL (Asm monad)
    ↓
Assembly Statements (instructions / labels / directives)
    ↓
Linker (2-pass: collect labels → resolve references → emit bytes)
    ↓
ROM Builder (Game Gear header at 0x7FF0, checksum, size validation)
    ↓
.gg ROM file
```

### Core Modules (`src/Z80/`)

- **`Types.hs`** — Core AST: `Reg8`, `Reg16`, `Condition`, `Instruction`, `Label`, `AddrExpr`
- **`Asm.hs`** — `Asm` monad (State-based); primitives: `emit`, `defineLabel`, `org`, `db`, `dw`, `ds`
- **`Opcodes.hs`** — User-facing instruction builders (`ld`, `ldi`, `inc`, `jp`, `addAn`, etc.)
- **`Encoder.hs`** — Converts `Instruction` to raw bytes using Z80 register/condition bit tables
- **`Linker.hs`** — 2-pass assembler; builds label map, resolves `LabelRef` / `Lit` address expressions, reports `LinkerError` for undefined labels, duplicate labels, and out-of-range relative jumps (`JR`/`DJNZ`)
- **`ROM/Builder.hs`** — Top-level `assemble :: ROMConfig -> Asm () -> Either AssemblerError ByteString`
- **`ROM/GameGear.hs`** — Game Gear ROM format: 16-byte header at `0x7FF0`, checksum, `ROMConfig`
- **`Platform/GameGear.hs`** — Hardware abstractions: VDP (ports `0xBE`/`0xBF`), palette, tiles, sprites, VBlank sync

### Test Infrastructure (`test/Emulicious/`)

Tests assemble a ROM, write it to `tmp/`, spawn Emulicious via the DAP (Debug Adapter Protocol) on port 58870, execute until `halt`, then read memory/registers to assert state.

- **`Runner.hs`** — Launches the emulator process and opens the DAP socket
- **`Assert.hs`** — `runROM`, `assertRAM`, `assertRAMRange` helpers
- **`DAP.hs`** — Low-level DAP protocol client over TCP

### Key Design Details

- **Two-pass label resolution**: First pass collects label positions; second pass resolves `LabelRef` forward references.
- **Relative jumps**: `JR`/`DJNZ` resolve to signed `Int8` offset; linker errors if out of range (±127 bytes).
- **Game Gear colors**: 4-bit RGB; CRAM format packs as `(lo: GGGGRRRRR, hi: 0000BBBB)`.
- **ROM header**: Must sit at `0x7FF0`–`0x7FFF`; checksum covers `0x0000`–`0x7FEF`.
