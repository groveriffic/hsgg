module Z80.Encoder
  ( encode
  , instrSize
  , reg8Code
  , reg16Code
  , condCode
  , rstByte
  ) where

import Data.Bits
import Data.Word (Word8, Word16)

import Z80.Types

-- ---------------------------------------------------------------------------
-- Register / condition codes
-- ---------------------------------------------------------------------------

-- | Z80 register encoding: B=0 C=1 D=2 E=3 H=4 L=5 (HL)=6 A=7
-- IXH/IYH map to 4 (H slot), IXL/IYL map to 5 (L slot) -- prefix selects IX/IY
reg8Code :: Reg8 -> Word8
reg8Code B   = 0
reg8Code C   = 1
reg8Code D   = 2
reg8Code E   = 3
reg8Code H   = 4
reg8Code L   = 5
reg8Code A   = 7
reg8Code IXH = 4
reg8Code IXL = 5
reg8Code IYH = 4
reg8Code IYL = 5
reg8Code I   = error "I register has no reg8 code in normal ops"
reg8Code R   = error "R register has no reg8 code in normal ops"

reg16Code :: Reg16 -> Word8
reg16Code BC  = 0
reg16Code DE  = 1
reg16Code HL  = 2
reg16Code SP  = 3
reg16Code AF  = 3  -- same slot as SP in push/pop context
reg16Code AF' = 3
reg16Code IX  = 2  -- same slot as HL, DD prefix selects IX
reg16Code IY  = 2  -- same slot as HL, FD prefix selects IY

condCode :: Condition -> Word8
condCode NZ = 0
condCode Z  = 1
condCode NC = 2
condCode CF = 3
condCode PO = 4
condCode PE = 5
condCode P  = 6
condCode M  = 7

rstByte :: RstTarget -> Word8
rstByte RST00 = 0x00
rstByte RST08 = 0x08
rstByte RST10 = 0x10
rstByte RST18 = 0x18
rstByte RST20 = 0x20
rstByte RST28 = 0x28
rstByte RST30 = 0x30
rstByte RST38 = 0x38

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

lo :: Word16 -> Word8
lo w = fromIntegral (w .&. 0xFF)

hi :: Word16 -> Word8
hi w = fromIntegral (w `shiftR` 8)

-- Split a resolved Word16 into [lo, hi]
word16le :: Word16 -> [Word8]
word16le w = [lo w, hi w]

-- AddrExpr must be resolved before encoding; use Lit for known values.
resolveAddr :: AddrExpr -> Word16
resolveAddr (Lit w)          = w
resolveAddr (LabelRef lbl)   = error $ "unresolved label: " <> show (labelName lbl)
resolveAddr (LabelRefLo lbl) = error $ "unresolved label lo: " <> show (labelName lbl)
resolveAddr (LabelRefHi lbl) = error $ "unresolved label hi: " <> show (labelName lbl)

addrBytes :: AddrExpr -> [Word8]
addrBytes e = word16le (resolveAddr e)

-- ---------------------------------------------------------------------------
-- instrSize: fixed size in bytes for every instruction
-- ---------------------------------------------------------------------------

instrSize :: Instruction -> Int
instrSize instr = length (encode instr)

-- ---------------------------------------------------------------------------
-- encode: instruction -> bytes
-- ---------------------------------------------------------------------------

encode :: Instruction -> [Word8]

-- ------------------------------------------------------------------ --
-- Misc
-- ------------------------------------------------------------------ --
encode NOP  = [0x00]
encode HALT = [0x76]
encode DI   = [0xF3]
encode EI   = [0xFB]
encode DAA  = [0x27]
encode CPL  = [0x2F]
encode CCF  = [0x3F]
encode SCF  = [0x37]
encode RLCA = [0x07]
encode RLA  = [0x17]
encode RRCA = [0x0F]
encode RRA  = [0x1F]

encode NEG  = [0xED, 0x44]
encode RETI = [0xED, 0x4D]
encode RETN = [0xED, 0x45]
encode RLD  = [0xED, 0x6F]
encode RRD  = [0xED, 0x67]

encode IM0  = [0xED, 0x46]
encode IM1  = [0xED, 0x56]
encode IM2  = [0xED, 0x5E]

-- ------------------------------------------------------------------ --
-- 8-bit loads: LD r, r'  (0x40 .. 0x7F, except 0x76 = HALT)
-- ------------------------------------------------------------------ --
encode (LD_r_r dst src) =
  [0x40 .|. (reg8Code dst `shiftL` 3) .|. reg8Code src]

encode (LD_r_n r n) =
  [0x06 .|. (reg8Code r `shiftL` 3), n]

encode (LD_r_HL r) =
  [0x46 .|. (reg8Code r `shiftL` 3)]

encode (LD_r_IXd r d) =
  [0xDD, 0x46 .|. (reg8Code r `shiftL` 3), fromIntegral d]

encode (LD_r_IYd r d) =
  [0xFD, 0x46 .|. (reg8Code r `shiftL` 3), fromIntegral d]

encode (LD_HL_r r) =
  [0x70 .|. reg8Code r]

encode (LD_IXd_r d r) =
  [0xDD, 0x70 .|. reg8Code r, fromIntegral d]

encode (LD_IYd_r d r) =
  [0xFD, 0x70 .|. reg8Code r, fromIntegral d]

encode (LD_HL_n n) =
  [0x36, n]

encode (LD_IXd_n d n) =
  [0xDD, 0x36, fromIntegral d, n]

encode (LD_IYd_n d n) =
  [0xFD, 0x36, fromIntegral d, n]

encode LD_A_BC = [0x0A]
encode LD_A_DE = [0x1A]

encode (LD_A_nn e) = 0x3A : addrBytes e

encode LD_BC_A = [0x02]
encode LD_DE_A = [0x12]

encode (LD_nn_A e) = 0x32 : addrBytes e

encode LD_A_I = [0xED, 0x57]
encode LD_A_R = [0xED, 0x5F]
encode LD_I_A = [0xED, 0x47]
encode LD_R_A = [0xED, 0x4F]

-- ------------------------------------------------------------------ --
-- 16-bit loads
-- ------------------------------------------------------------------ --
encode (LD_rr_nn rr e) =
  (0x01 .|. (reg16Code rr `shiftL` 4)) : addrBytes e

encode (LD_HL_ind e)    = 0x2A : addrBytes e
encode (LD_nn_HL  e)    = 0x22 : addrBytes e

encode (LD_rr_ind BC e) = [0xED, 0x4B] <> addrBytes e
encode (LD_rr_ind DE e) = [0xED, 0x5B] <> addrBytes e
encode (LD_rr_ind HL e) = 0x2A : addrBytes e   -- same as LD_HL_ind
encode (LD_rr_ind SP e) = [0xED, 0x7B] <> addrBytes e
encode (LD_rr_ind _  e) = [0xED, 0x7B] <> addrBytes e   -- fallback

encode (LD_nn_rr  e BC) = [0xED, 0x43] <> addrBytes e
encode (LD_nn_rr  e DE) = [0xED, 0x53] <> addrBytes e
encode (LD_nn_rr  e HL) = 0x22 : addrBytes e
encode (LD_nn_rr  e SP) = [0xED, 0x73] <> addrBytes e
encode (LD_nn_rr  e _)  = [0xED, 0x73] <> addrBytes e   -- fallback

encode LD_SP_HL = [0xF9]
encode LD_SP_IX = [0xDD, 0xF9]
encode LD_SP_IY = [0xFD, 0xF9]

encode (PUSH_rr AF)  = [0xF5]
encode (PUSH_rr AF') = [0xF5]
encode (PUSH_rr BC)  = [0xC5]
encode (PUSH_rr DE)  = [0xD5]
encode (PUSH_rr HL)  = [0xE5]
encode (PUSH_rr IX)  = [0xDD, 0xE5]
encode (PUSH_rr IY)  = [0xFD, 0xE5]
encode (PUSH_rr _)   = [0xE5]   -- fallback

encode (POP_rr AF)  = [0xF1]
encode (POP_rr AF') = [0xF1]
encode (POP_rr BC)  = [0xC1]
encode (POP_rr DE)  = [0xD1]
encode (POP_rr HL)  = [0xE1]
encode (POP_rr IX)  = [0xDD, 0xE1]
encode (POP_rr IY)  = [0xFD, 0xE1]
encode (POP_rr _)   = [0xE1]   -- fallback

-- ------------------------------------------------------------------ --
-- Exchange
-- ------------------------------------------------------------------ --
encode EX_DE_HL  = [0xEB]
encode EX_AF_AF' = [0x08]
encode EXX       = [0xD9]
encode EX_SP_HL  = [0xE3]
encode EX_SP_IX  = [0xDD, 0xE3]
encode EX_SP_IY  = [0xFD, 0xE3]

-- ------------------------------------------------------------------ --
-- 8-bit arithmetic helpers
-- ------------------------------------------------------------------ --
-- ADD A, r  0x80+r
encode (ADD_A_r r)     = [0x80 .|. reg8Code r]
encode (ADD_A_n n)     = [0xC6, n]
encode ADD_A_HL        = [0x86]
encode (ADD_A_IXd d)   = [0xDD, 0x86, fromIntegral d]
encode (ADD_A_IYd d)   = [0xFD, 0x86, fromIntegral d]

encode (ADC_A_r r)     = [0x88 .|. reg8Code r]
encode (ADC_A_n n)     = [0xCE, n]
encode ADC_A_HL        = [0x8E]
encode (ADC_A_IXd d)   = [0xDD, 0x8E, fromIntegral d]
encode (ADC_A_IYd d)   = [0xFD, 0x8E, fromIntegral d]

encode (SUB_r r)       = [0x90 .|. reg8Code r]
encode (SUB_n n)       = [0xD6, n]
encode SUB_HL          = [0x96]
encode (SUB_IXd d)     = [0xDD, 0x96, fromIntegral d]
encode (SUB_IYd d)     = [0xFD, 0x96, fromIntegral d]

encode (SBC_A_r r)     = [0x98 .|. reg8Code r]
encode (SBC_A_n n)     = [0xDE, n]
encode SBC_A_HL        = [0x9E]
encode (SBC_A_IXd d)   = [0xDD, 0x9E, fromIntegral d]
encode (SBC_A_IYd d)   = [0xFD, 0x9E, fromIntegral d]

encode (AND_r r)       = [0xA0 .|. reg8Code r]
encode (AND_n n)       = [0xE6, n]
encode AND_HL          = [0xA6]
encode (AND_IXd d)     = [0xDD, 0xA6, fromIntegral d]
encode (AND_IYd d)     = [0xFD, 0xA6, fromIntegral d]

encode (XOR_r r)       = [0xA8 .|. reg8Code r]
encode (XOR_n n)       = [0xEE, n]
encode XOR_HL          = [0xAE]
encode (XOR_IXd d)     = [0xDD, 0xAE, fromIntegral d]
encode (XOR_IYd d)     = [0xFD, 0xAE, fromIntegral d]

encode (OR_r r)        = [0xB0 .|. reg8Code r]
encode (OR_n n)        = [0xF6, n]
encode OR_HL           = [0xB6]
encode (OR_IXd d)      = [0xDD, 0xB6, fromIntegral d]
encode (OR_IYd d)      = [0xFD, 0xB6, fromIntegral d]

encode (CP_r r)        = [0xB8 .|. reg8Code r]
encode (CP_n n)        = [0xFE, n]
encode CP_HL           = [0xBE]
encode (CP_IXd d)      = [0xDD, 0xBE, fromIntegral d]
encode (CP_IYd d)      = [0xFD, 0xBE, fromIntegral d]

encode (INC_r r)       = [0x04 .|. (reg8Code r `shiftL` 3)]
encode INC_HL          = [0x34]
encode (INC_IXd d)     = [0xDD, 0x34, fromIntegral d]
encode (INC_IYd d)     = [0xFD, 0x34, fromIntegral d]

encode (DEC_r r)       = [0x05 .|. (reg8Code r `shiftL` 3)]
encode DEC_HL          = [0x35]
encode (DEC_IXd d)     = [0xDD, 0x35, fromIntegral d]
encode (DEC_IYd d)     = [0xFD, 0x35, fromIntegral d]

-- ------------------------------------------------------------------ --
-- 16-bit arithmetic
-- ------------------------------------------------------------------ --
encode (ADD_HL_rr rr)  = [0x09 .|. (reg16Code rr `shiftL` 4)]
encode (ADD_IX_rr rr)  = [0xDD, 0x09 .|. (reg16Code rr `shiftL` 4)]
encode (ADD_IY_rr rr)  = [0xFD, 0x09 .|. (reg16Code rr `shiftL` 4)]
encode (ADC_HL_rr rr)  = [0xED, 0x4A .|. (reg16Code rr `shiftL` 4)]
encode (SBC_HL_rr rr)  = [0xED, 0x42 .|. (reg16Code rr `shiftL` 4)]
encode (INC_rr rr)     = [0x03 .|. (reg16Code rr `shiftL` 4)]
encode (DEC_rr rr)     = [0x0B .|. (reg16Code rr `shiftL` 4)]

-- ------------------------------------------------------------------ --
-- CB-prefixed rotates / shifts on registers
-- ------------------------------------------------------------------ --
encode (RLC_r  r) = [0xCB, 0x00 .|. reg8Code r]
encode (RRC_r  r) = [0xCB, 0x08 .|. reg8Code r]
encode (RL_r   r) = [0xCB, 0x10 .|. reg8Code r]
encode (RR_r   r) = [0xCB, 0x18 .|. reg8Code r]
encode (SLA_r  r) = [0xCB, 0x20 .|. reg8Code r]
encode (SRA_r  r) = [0xCB, 0x28 .|. reg8Code r]
encode (SLL_r  r) = [0xCB, 0x30 .|. reg8Code r]   -- undocumented
encode (SRL_r  r) = [0xCB, 0x38 .|. reg8Code r]

encode RLC_HL = [0xCB, 0x06]
encode RRC_HL = [0xCB, 0x0E]
encode RL_HL  = [0xCB, 0x16]
encode RR_HL  = [0xCB, 0x1E]
encode SLA_HL = [0xCB, 0x26]
encode SRA_HL = [0xCB, 0x2E]
encode SLL_HL = [0xCB, 0x36]
encode SRL_HL = [0xCB, 0x3E]

-- DDCB / FDCB shifts on (IX+d) / (IY+d)
encode (RLC_IXd d) = [0xDD, 0xCB, fromIntegral d, 0x06]
encode (RRC_IXd d) = [0xDD, 0xCB, fromIntegral d, 0x0E]
encode (RL_IXd  d) = [0xDD, 0xCB, fromIntegral d, 0x16]
encode (RR_IXd  d) = [0xDD, 0xCB, fromIntegral d, 0x1E]
encode (SLA_IXd d) = [0xDD, 0xCB, fromIntegral d, 0x26]
encode (SRA_IXd d) = [0xDD, 0xCB, fromIntegral d, 0x2E]
encode (SLL_IXd d) = [0xDD, 0xCB, fromIntegral d, 0x36]
encode (SRL_IXd d) = [0xDD, 0xCB, fromIntegral d, 0x3E]

encode (RLC_IYd d) = [0xFD, 0xCB, fromIntegral d, 0x06]
encode (RRC_IYd d) = [0xFD, 0xCB, fromIntegral d, 0x0E]
encode (RL_IYd  d) = [0xFD, 0xCB, fromIntegral d, 0x16]
encode (RR_IYd  d) = [0xFD, 0xCB, fromIntegral d, 0x1E]
encode (SLA_IYd d) = [0xFD, 0xCB, fromIntegral d, 0x26]
encode (SRA_IYd d) = [0xFD, 0xCB, fromIntegral d, 0x2E]
encode (SLL_IYd d) = [0xFD, 0xCB, fromIntegral d, 0x36]
encode (SRL_IYd d) = [0xFD, 0xCB, fromIntegral d, 0x3E]

-- ------------------------------------------------------------------ --
-- CB-prefixed BIT / SET / RES on registers
-- ------------------------------------------------------------------ --
encode (BIT_b_r b r) = [0xCB, 0x40 .|. (fromIntegral b `shiftL` 3) .|. reg8Code r]
encode (SET_b_r b r) = [0xCB, 0xC0 .|. (fromIntegral b `shiftL` 3) .|. reg8Code r]
encode (RES_b_r b r) = [0xCB, 0x80 .|. (fromIntegral b `shiftL` 3) .|. reg8Code r]

encode (BIT_b_HL b)  = [0xCB, 0x46 .|. (fromIntegral b `shiftL` 3)]
encode (SET_b_HL b)  = [0xCB, 0xC6 .|. (fromIntegral b `shiftL` 3)]
encode (RES_b_HL b)  = [0xCB, 0x86 .|. (fromIntegral b `shiftL` 3)]

encode (BIT_b_IXd b d) = [0xDD, 0xCB, fromIntegral d, 0x46 .|. (fromIntegral b `shiftL` 3)]
encode (SET_b_IXd b d) = [0xDD, 0xCB, fromIntegral d, 0xC6 .|. (fromIntegral b `shiftL` 3)]
encode (RES_b_IXd b d) = [0xDD, 0xCB, fromIntegral d, 0x86 .|. (fromIntegral b `shiftL` 3)]

encode (BIT_b_IYd b d) = [0xFD, 0xCB, fromIntegral d, 0x46 .|. (fromIntegral b `shiftL` 3)]
encode (SET_b_IYd b d) = [0xFD, 0xCB, fromIntegral d, 0xC6 .|. (fromIntegral b `shiftL` 3)]
encode (RES_b_IYd b d) = [0xFD, 0xCB, fromIntegral d, 0x86 .|. (fromIntegral b `shiftL` 3)]

-- ------------------------------------------------------------------ --
-- Jumps  (AddrExpr must be resolved to Lit by the linker)
-- ------------------------------------------------------------------ --
encode (JP e)       = 0xC3 : addrBytes e
encode (JP_cc c e)  = (0xC2 .|. (condCode c `shiftL` 3)) : addrBytes e
encode JP_HL        = [0xE9]
encode JP_IX        = [0xDD, 0xE9]
encode JP_IY        = [0xFD, 0xE9]

-- JR uses a signed byte offset relative to the instruction after the JR.
-- The linker stores the resolved offset in a Lit (cast to Word16, then take lo byte).
encode (JR e)       = [0x18, lo (resolveAddr e)]
encode (JR_cc c e)  = [0x20 .|. (condCode c `shiftL` 3), lo (resolveAddr e)]
encode (DJNZ e)     = [0x10, lo (resolveAddr e)]

-- ------------------------------------------------------------------ --
-- Calls / returns
-- ------------------------------------------------------------------ --
encode (CALL e)      = 0xCD : addrBytes e
encode (CALL_cc c e) = (0xC4 .|. (condCode c `shiftL` 3)) : addrBytes e
encode RET           = [0xC9]
encode (RET_cc c)    = [0xC0 .|. (condCode c `shiftL` 3)]
encode (RST t)       = [0xC7 .|. rstByte t]

-- ------------------------------------------------------------------ --
-- I/O
-- ------------------------------------------------------------------ --
encode (IN_A_n n)    = [0xDB, n]
encode (IN_r_C r)    = [0xED, 0x40 .|. (reg8Code r `shiftL` 3)]
encode (OUT_n_A n)   = [0xD3, n]
encode (OUT_C_r r)   = [0xED, 0x41 .|. (reg8Code r `shiftL` 3)]

encode INI  = [0xED, 0xA2]
encode IND  = [0xED, 0xAA]
encode INIR = [0xED, 0xB2]
encode INDR = [0xED, 0xBA]
encode OUTI = [0xED, 0xA3]
encode OUTD = [0xED, 0xAB]
encode OTIR = [0xED, 0xB3]
encode OTDR = [0xED, 0xBB]

-- ------------------------------------------------------------------ --
-- Block operations
-- ------------------------------------------------------------------ --
encode LDI  = [0xED, 0xA0]
encode LDD  = [0xED, 0xA8]
encode LDIR = [0xED, 0xB0]
encode LDDR = [0xED, 0xB8]
encode CPI  = [0xED, 0xA1]
encode CPD  = [0xED, 0xA9]
encode CPIR = [0xED, 0xB1]
encode CPDR = [0xED, 0xB9]
