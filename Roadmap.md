# Roadmap

## Priority

1. **Input** — no interactive program is possible without it
2. **Control Flow DSL** — `if`/`while` combinators improve every subsequent feature
3. **Interrupt Handling** — ISR-based VBlank and NMI underpin reliable game loops and raster effects
4. **Game Architecture** — state machine + entity management needed before a real game is possible
5. **Debug Tooling** — symbol output pays off immediately during development
6. **Scrolling / Screen Coordinates** — core graphics capability; unblocks most game types
7. **Composite Sprites / Raster Effects** — richer visuals once the basics are solid
8. **Collision Detection** — required for gameplay logic
9. **Audio** — BGM and SFX done; Voice speculative
10. **Bank Switching** — unblocks programs larger than 32KB
11. **Static Analysis** (timing, emulation tests) — polish and confidence tooling
12. **SRAM / Save Data** — late-stage feature for shipping games
13. **Voice** — speculative; extremely constrained on GG hardware

---

## Input
### Button Abstraction
- GG start button (port 0x00), d-pad, and two action buttons
- Debouncing helpers
- Button combination helpers
- Button sequence helpers

## Graphics
### Scrolling

Does this move the view port?
Requires VDP research.

### Screen Coordinates Type

Let developer specify screen coordinates.
Attempt to resolve coordinates at compile time.
Note: screen-space vs. world-space only makes sense once scroll position is
part of the model — consider treating this and Scrolling as one feature.

### Composite Sprites
- Multiple sprites in a frame
- Animate frames
- Entity tables for runtime sprite management (see also: Game Architecture)

### Raster Effects
- H-blank line interrupts for mid-frame palette/scroll changes
- Requires interrupt handling (see below)

## Interrupt Handling
### VBlank ISR
- Jump table at 0x0038 for ISR-based VBlank (vs. current polling approach)
### NMI / Pause Button
- GG pause button triggers NMI at 0x0066
### H-Blank
- Line interrupt for raster effects

## Control Flow DSL
Higher-level combinators over raw labels and jumps — a natural fit for a
Haskell eDSL.
- `ifAsm` / `elseAsm`
- `whileAsm`
- `doWhileAsm`

## Game Architecture
### Scene / State Machine
- Abstraction for switching between game states (title, gameplay, game over)
### Entity Management
- Sprite/object tables with per-entity position, velocity, state
### Frame Loop
- Structured main loop with fixed-timestep update and render phases
### Timer / Counter Infrastructure
- Frame counters, cooldown timers

## Memory
### Bank Switching
- GG supports ROMs up to 512KB via the Sega mapper (registers 0xFFFC–0xFFFF)
- Without this the DSL is limited to 32KB programs
### SRAM / Save Data
- Battery-backed SRAM support for persistent game state

## Physics
### Collision Detection

## Audio
### Voice?
- 1-bit PCM via PSG envelope tricks; extremely constrained on GG — speculative

## Debug Tooling
### Annotated Disassembly
- Human-readable disassembly with label names for inspection

## Static Analysis
### Timing
- Milliseconds, Microseconds?
- Clock Cycles or whatever is customary for Z80
- Test suite to ensure a routine fits within a performance budget

### Emulation Test
- [x] Build minimal rom
- [x] Run emulator
- [x] Make assertions on emulator state
- [ ] Make assertions on screen shot capture
