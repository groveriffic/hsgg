module Z80.Types
  ( Reg8 (..)
  , Reg16 (..)
  , Condition (..)
  , Label (..)
  , AddrExpr (..)
  , RstTarget (..)
  , Instruction (..)
  ) where

import Data.Int  (Int8)
import Data.Word (Word8, Word16)
import Data.Text (Text)

-- | 8-bit registers
data Reg8
  = A | B | C | D | E | H | L
  | IXH | IXL | IYH | IYL
  | I | R
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | 16-bit register pairs
data Reg16
  = BC | DE | HL | SP | AF | AF' | IX | IY
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Condition codes for conditional jumps/calls/returns
data Condition
  = NZ | Z | NC | CF | PO | PE | P | M
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | A symbolic label
newtype Label = Label { labelName :: Text }
  deriving (Show, Eq, Ord)

-- | An address expression: resolved or label-based
data AddrExpr
  = Lit    Word16
  | LabelRef   Label
  | LabelRefLo Label  -- low byte of label address
  | LabelRefHi Label  -- high byte of label address
  deriving (Show, Eq)

-- | RST call targets
data RstTarget
  = RST00 | RST08 | RST10 | RST18
  | RST20 | RST28 | RST30 | RST38
  deriving (Show, Eq, Ord, Enum, Bounded)

-- | Complete Z80 instruction set (documented + commonly-used undocumented)
data Instruction
  -- ------------------------------------------------------------------ --
  -- 8-bit loads
  -- ------------------------------------------------------------------ --
  = LD_r_r    Reg8 Reg8         -- LD r, r'
  | LD_r_n    Reg8 Word8        -- LD r, n
  | LD_r_HL   Reg8              -- LD r, (HL)
  | LD_r_IXd  Reg8 Int8         -- LD r, (IX+d)
  | LD_r_IYd  Reg8 Int8         -- LD r, (IY+d)
  | LD_HL_r   Reg8              -- LD (HL), r
  | LD_IXd_r  Int8 Reg8         -- LD (IX+d), r
  | LD_IYd_r  Int8 Reg8         -- LD (IY+d), r
  | LD_HL_n   Word8             -- LD (HL), n
  | LD_IXd_n  Int8 Word8        -- LD (IX+d), n
  | LD_IYd_n  Int8 Word8        -- LD (IY+d), n
  | LD_A_BC                     -- LD A, (BC)
  | LD_A_DE                     -- LD A, (DE)
  | LD_A_nn   AddrExpr          -- LD A, (nn)
  | LD_BC_A                     -- LD (BC), A
  | LD_DE_A                     -- LD (DE), A
  | LD_nn_A   AddrExpr          -- LD (nn), A
  | LD_A_I                      -- LD A, I
  | LD_A_R                      -- LD A, R
  | LD_I_A                      -- LD I, A
  | LD_R_A                      -- LD R, A

  -- ------------------------------------------------------------------ --
  -- 16-bit loads
  -- ------------------------------------------------------------------ --
  | LD_rr_nn   Reg16 AddrExpr   -- LD rr, nn
  | LD_HL_ind  AddrExpr         -- LD HL, (nn)
  | LD_rr_ind  Reg16 AddrExpr   -- LD rr, (nn)  [ED-prefixed]
  | LD_nn_HL   AddrExpr         -- LD (nn), HL
  | LD_nn_rr   AddrExpr Reg16   -- LD (nn), rr  [ED-prefixed]
  | LD_SP_HL                    -- LD SP, HL
  | LD_SP_IX                    -- LD SP, IX
  | LD_SP_IY                    -- LD SP, IY
  | PUSH_rr    Reg16
  | POP_rr     Reg16

  -- ------------------------------------------------------------------ --
  -- Exchange
  -- ------------------------------------------------------------------ --
  | EX_DE_HL
  | EX_AF_AF'
  | EXX
  | EX_SP_HL
  | EX_SP_IX
  | EX_SP_IY

  -- ------------------------------------------------------------------ --
  -- 8-bit arithmetic / logic
  -- ------------------------------------------------------------------ --
  | ADD_A_r   Reg8  | ADD_A_n  Word8 | ADD_A_HL | ADD_A_IXd Int8 | ADD_A_IYd Int8
  | ADC_A_r   Reg8  | ADC_A_n  Word8 | ADC_A_HL | ADC_A_IXd Int8 | ADC_A_IYd Int8
  | SUB_r     Reg8  | SUB_n    Word8 | SUB_HL   | SUB_IXd   Int8 | SUB_IYd   Int8
  | SBC_A_r   Reg8  | SBC_A_n  Word8 | SBC_A_HL | SBC_A_IXd Int8 | SBC_A_IYd Int8
  | AND_r     Reg8  | AND_n    Word8 | AND_HL   | AND_IXd   Int8 | AND_IYd   Int8
  | OR_r      Reg8  | OR_n     Word8 | OR_HL    | OR_IXd    Int8 | OR_IYd    Int8
  | XOR_r     Reg8  | XOR_n    Word8 | XOR_HL   | XOR_IXd   Int8 | XOR_IYd   Int8
  | CP_r      Reg8  | CP_n     Word8 | CP_HL    | CP_IXd    Int8 | CP_IYd    Int8
  | INC_r     Reg8  | INC_HL   | INC_IXd Int8   | INC_IYd   Int8
  | DEC_r     Reg8  | DEC_HL   | DEC_IXd Int8   | DEC_IYd   Int8

  -- ------------------------------------------------------------------ --
  -- 16-bit arithmetic
  -- ------------------------------------------------------------------ --
  | ADD_HL_rr  Reg16
  | ADD_IX_rr  Reg16
  | ADD_IY_rr  Reg16
  | ADC_HL_rr  Reg16
  | SBC_HL_rr  Reg16
  | INC_rr     Reg16
  | DEC_rr     Reg16

  -- ------------------------------------------------------------------ --
  -- Rotate / shift  (unprefixed + CB prefix)
  -- ------------------------------------------------------------------ --
  | RLCA | RLA | RRCA | RRA
  | RLC_r  Reg8 | RRC_r  Reg8 | RL_r   Reg8 | RR_r   Reg8
  | SLA_r  Reg8 | SRA_r  Reg8 | SRL_r  Reg8 | SLL_r  Reg8
  | RLC_HL | RRC_HL | RL_HL | RR_HL | SLA_HL | SRA_HL | SRL_HL | SLL_HL
  | RLC_IXd Int8 | RRC_IXd Int8 | RL_IXd Int8 | RR_IXd Int8
  | SLA_IXd Int8 | SRA_IXd Int8 | SRL_IXd Int8 | SLL_IXd Int8
  | RLC_IYd Int8 | RRC_IYd Int8 | RL_IYd Int8 | RR_IYd Int8
  | SLA_IYd Int8 | SRA_IYd Int8 | SRL_IYd Int8 | SLL_IYd Int8

  -- ------------------------------------------------------------------ --
  -- Bit manipulation  (CB / DDCB / FDCB)
  -- ------------------------------------------------------------------ --
  | BIT_b_r   Int Reg8 | BIT_b_HL Int | BIT_b_IXd Int Int8 | BIT_b_IYd Int Int8
  | SET_b_r   Int Reg8 | SET_b_HL Int | SET_b_IXd Int Int8 | SET_b_IYd Int Int8
  | RES_b_r   Int Reg8 | RES_b_HL Int | RES_b_IXd Int Int8 | RES_b_IYd Int Int8

  -- ------------------------------------------------------------------ --
  -- Jumps
  -- ------------------------------------------------------------------ --
  | JP      AddrExpr
  | JP_cc   Condition AddrExpr
  | JP_HL | JP_IX | JP_IY
  | JR      AddrExpr            -- relative jump (label resolved to Int8 offset)
  | JR_cc   Condition AddrExpr
  | DJNZ    AddrExpr

  -- ------------------------------------------------------------------ --
  -- Calls / returns
  -- ------------------------------------------------------------------ --
  | CALL    AddrExpr
  | CALL_cc Condition AddrExpr
  | RET
  | RET_cc  Condition
  | RETI
  | RETN
  | RST     RstTarget

  -- ------------------------------------------------------------------ --
  -- I/O
  -- ------------------------------------------------------------------ --
  | IN_A_n   Word8
  | IN_r_C   Reg8
  | OUT_n_A  Word8
  | OUT_C_r  Reg8
  | INI | IND | INIR | INDR
  | OUTI | OUTD | OTIR | OTDR

  -- ------------------------------------------------------------------ --
  -- Block operations
  -- ------------------------------------------------------------------ --
  | LDI | LDD | LDIR | LDDR
  | CPI | CPD | CPIR | CPDR

  -- ------------------------------------------------------------------ --
  -- Miscellaneous
  -- ------------------------------------------------------------------ --
  | NOP | HALT | DI | EI
  | DAA | CPL | NEG | CCF | SCF
  | IM0 | IM1 | IM2
  | RLD | RRD

  deriving (Show, Eq)
