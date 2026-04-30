-- | Z80 interrupt service routine helpers.
module Z80.ISR
  ( isrEnter
  , isrLeave
  , enableVBlankIRQ
  ) where

import Z80.Types   (Reg16 (AF, BC, DE, HL))
import Z80.Asm     (Asm)
import Z80.Opcodes (im1, ei, reti, push, pop)

-- | Save AF, BC, DE, HL onto the stack (ISR prologue).
isrEnter :: Asm ()
isrEnter = mapM_ push [AF, BC, DE, HL]

-- | Restore HL, DE, BC, AF and return from interrupt (ISR epilogue).
-- Uses 'ei' + 'reti' as required by the Z80 interrupt controller.
isrLeave :: Asm ()
isrLeave = do
  mapM_ pop [HL, DE, BC, AF]
  ei
  reti

-- | Switch to IM 1 and enable maskable interrupts.
-- Call after all VRAM data is loaded.
enableVBlankIRQ :: Asm ()
enableVBlankIRQ = do
  im1
  ei
