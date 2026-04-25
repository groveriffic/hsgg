{-# OPTIONS_GHC -Wno-missing-export-lists #-}
-- | DSL smart constructors — one per opcode form.
-- Import this module to write Z80 assembly using do-notation.
module Z80.Opcodes where

import Data.Int  (Int8)
import Data.Word (Word8, Word16)

import Z80.Types
import Z80.Asm   (Asm, emit)

-- ---------------------------------------------------------------------------
-- Miscellaneous
-- ---------------------------------------------------------------------------

nop, halt, di, ei :: Asm ()
nop  = emit NOP
halt = emit HALT
di   = emit DI
ei   = emit EI

daa, cpl, neg, ccf, scf :: Asm ()
daa = emit DAA
cpl = emit CPL
neg = emit NEG
ccf = emit CCF
scf = emit SCF

rlca, rla, rrca, rra :: Asm ()
rlca = emit RLCA
rla  = emit RLA
rrca = emit RRCA
rra  = emit RRA

im0, im1, im2 :: Asm ()
im0 = emit IM0
im1 = emit IM1
im2 = emit IM2

rld, rrd :: Asm ()
rld = emit RLD
rrd = emit RRD

reti, retn :: Asm ()
reti = emit RETI
retn = emit RETN

-- ---------------------------------------------------------------------------
-- 8-bit loads
-- ---------------------------------------------------------------------------

ld :: Reg8 -> Reg8 -> Asm ()
ld dst src = emit (LD_r_r dst src)

ldi :: Reg8 -> Word8 -> Asm ()
ldi r n = emit (LD_r_n r n)

ldHL :: Reg8 -> Asm ()
ldHL r = emit (LD_r_HL r)

ldIX :: Reg8 -> Int8 -> Asm ()
ldIX r d = emit (LD_r_IXd r d)

ldIY :: Reg8 -> Int8 -> Asm ()
ldIY r d = emit (LD_r_IYd r d)

stHL :: Reg8 -> Asm ()
stHL r = emit (LD_HL_r r)

stIX :: Int8 -> Reg8 -> Asm ()
stIX d r = emit (LD_IXd_r d r)

stIY :: Int8 -> Reg8 -> Asm ()
stIY d r = emit (LD_IYd_r d r)

stHLn :: Word8 -> Asm ()
stHLn n = emit (LD_HL_n n)

stIXn :: Int8 -> Word8 -> Asm ()
stIXn d n = emit (LD_IXd_n d n)

stIYn :: Int8 -> Word8 -> Asm ()
stIYn d n = emit (LD_IYd_n d n)

ldABC, ldADE :: Asm ()
ldABC = emit LD_A_BC
ldADE = emit LD_A_DE

ldAnn :: AddrExpr -> Asm ()
ldAnn e = emit (LD_A_nn e)

stBC, stDE :: Asm ()
stBC = emit LD_BC_A
stDE = emit LD_DE_A

stnn :: AddrExpr -> Asm ()
stnn e = emit (LD_nn_A e)

ldAI, ldAR, ldIA, ldRA :: Asm ()
ldAI = emit LD_A_I
ldAR = emit LD_A_R
ldIA = emit LD_I_A
ldRA = emit LD_R_A

-- ---------------------------------------------------------------------------
-- 16-bit loads
-- ---------------------------------------------------------------------------

ld16 :: Reg16 -> AddrExpr -> Asm ()
ld16 rr e = emit (LD_rr_nn rr e)

ld16n :: Reg16 -> Word16 -> Asm ()
ld16n rr n = emit (LD_rr_nn rr (Lit n))

ldHLind :: AddrExpr -> Asm ()
ldHLind e = emit (LD_HL_ind e)

ldRRind :: Reg16 -> AddrExpr -> Asm ()
ldRRind rr e = emit (LD_rr_ind rr e)

stHLaddr :: AddrExpr -> Asm ()
stHLaddr e = emit (LD_nn_HL e)

stRRaddr :: AddrExpr -> Reg16 -> Asm ()
stRRaddr e rr = emit (LD_nn_rr e rr)

ldSPHL, ldSPIX, ldSPIY :: Asm ()
ldSPHL = emit LD_SP_HL
ldSPIX = emit LD_SP_IX
ldSPIY = emit LD_SP_IY

push, pop :: Reg16 -> Asm ()
push rr = emit (PUSH_rr rr)
pop  rr = emit (POP_rr  rr)

-- ---------------------------------------------------------------------------
-- Exchange
-- ---------------------------------------------------------------------------

exDEHL, exAFAF', exx, exSPHL, exSPIX, exSPIY :: Asm ()
exDEHL  = emit EX_DE_HL
exAFAF' = emit EX_AF_AF'
exx     = emit EXX
exSPHL  = emit EX_SP_HL
exSPIX  = emit EX_SP_IX
exSPIY  = emit EX_SP_IY

-- ---------------------------------------------------------------------------
-- 8-bit arithmetic (register / immediate / (HL) / (IX+d) / (IY+d))
-- ---------------------------------------------------------------------------

addA, adcA, subA, sbcA, andA, xorA, orA, cpA :: Reg8 -> Asm ()
addA r = emit (ADD_A_r r)
adcA r = emit (ADC_A_r r)
subA r = emit (SUB_r   r)
sbcA r = emit (SBC_A_r r)
andA r = emit (AND_r   r)
xorA r = emit (XOR_r   r)
orA  r = emit (OR_r    r)
cpA  r = emit (CP_r    r)

addAn, adcAn, subAn, sbcAn, andAn, xorAn, orAn, cpAn :: Word8 -> Asm ()
addAn n = emit (ADD_A_n n)
adcAn n = emit (ADC_A_n n)
subAn n = emit (SUB_n   n)
sbcAn n = emit (SBC_A_n n)
andAn n = emit (AND_n   n)
xorAn n = emit (XOR_n   n)
orAn  n = emit (OR_n    n)
cpAn  n = emit (CP_n    n)

addAHL, adcAHL, subHL, sbcAHL, andHL, xorHL, orHL, cpHL :: Asm ()
addAHL = emit ADD_A_HL
adcAHL = emit ADC_A_HL
subHL  = emit SUB_HL
sbcAHL = emit SBC_A_HL
andHL  = emit AND_HL
xorHL  = emit XOR_HL
orHL   = emit OR_HL
cpHL   = emit CP_HL

addAIX, adcAIX, subIX, sbcAIX, andIX, xorIX, orIX, cpIX :: Int8 -> Asm ()
addAIX d = emit (ADD_A_IXd d)
adcAIX d = emit (ADC_A_IXd d)
subIX  d = emit (SUB_IXd d)
sbcAIX d = emit (SBC_A_IXd d)
andIX  d = emit (AND_IXd d)
xorIX  d = emit (XOR_IXd d)
orIX   d = emit (OR_IXd d)
cpIX   d = emit (CP_IXd d)

addAIY, adcAIY, subIY, sbcAIY, andIY, xorIY, orIY, cpIY :: Int8 -> Asm ()
addAIY d = emit (ADD_A_IYd d)
adcAIY d = emit (ADC_A_IYd d)
subIY  d = emit (SUB_IYd d)
sbcAIY d = emit (SBC_A_IYd d)
andIY  d = emit (AND_IYd d)
xorIY  d = emit (XOR_IYd d)
orIY   d = emit (OR_IYd d)
cpIY   d = emit (CP_IYd d)

inc, dec :: Reg8 -> Asm ()
inc r = emit (INC_r r)
dec r = emit (DEC_r r)

incHL, decHL :: Asm ()
incHL = emit INC_HL
decHL = emit DEC_HL

incIX, decIX :: Int8 -> Asm ()
incIX d = emit (INC_IXd d)
decIX d = emit (DEC_IXd d)

incIY, decIY :: Int8 -> Asm ()
incIY d = emit (INC_IYd d)
decIY d = emit (DEC_IYd d)

-- ---------------------------------------------------------------------------
-- 16-bit arithmetic
-- ---------------------------------------------------------------------------

addHL, addIX, addIY :: Reg16 -> Asm ()
addHL rr = emit (ADD_HL_rr rr)
addIX rr = emit (ADD_IX_rr rr)
addIY rr = emit (ADD_IY_rr rr)

adcHL, sbcHL :: Reg16 -> Asm ()
adcHL rr = emit (ADC_HL_rr rr)
sbcHL rr = emit (SBC_HL_rr rr)

inc16, dec16 :: Reg16 -> Asm ()
inc16 rr = emit (INC_rr rr)
dec16 rr = emit (DEC_rr rr)

-- ---------------------------------------------------------------------------
-- Rotate / shift
-- ---------------------------------------------------------------------------

rlcR, rrcR, rlR, rrR, slaR, sraR, sllR, srlR :: Reg8 -> Asm ()
rlcR r = emit (RLC_r r)
rrcR r = emit (RRC_r r)
rlR  r = emit (RL_r  r)
rrR  r = emit (RR_r  r)
slaR r = emit (SLA_r r)
sraR r = emit (SRA_r r)
sllR r = emit (SLL_r r)
srlR r = emit (SRL_r r)

rlcHL, rrcHL, rlHL, rrHL, slaHL, sraHL, sllHL, srlHL :: Asm ()
rlcHL = emit RLC_HL
rrcHL = emit RRC_HL
rlHL  = emit RL_HL
rrHL  = emit RR_HL
slaHL = emit SLA_HL
sraHL = emit SRA_HL
sllHL = emit SLL_HL
srlHL = emit SRL_HL

rlcIX, rrcIX, rlIX, rrIX, slaIX, sraIX, sllIX, srlIX :: Int8 -> Asm ()
rlcIX d = emit (RLC_IXd d)
rrcIX d = emit (RRC_IXd d)
rlIX  d = emit (RL_IXd  d)
rrIX  d = emit (RR_IXd  d)
slaIX d = emit (SLA_IXd d)
sraIX d = emit (SRA_IXd d)
sllIX d = emit (SLL_IXd d)
srlIX d = emit (SRL_IXd d)

rlcIY, rrcIY, rlIY, rrIY, slaIY, sraIY, sllIY, srlIY :: Int8 -> Asm ()
rlcIY d = emit (RLC_IYd d)
rrcIY d = emit (RRC_IYd d)
rlIY  d = emit (RL_IYd  d)
rrIY  d = emit (RR_IYd  d)
slaIY d = emit (SLA_IYd d)
sraIY d = emit (SRA_IYd d)
sllIY d = emit (SLL_IYd d)
srlIY d = emit (SRL_IYd d)

-- ---------------------------------------------------------------------------
-- Bit operations
-- ---------------------------------------------------------------------------

bit, set, res :: Int -> Reg8 -> Asm ()
bit b r = emit (BIT_b_r b r)
set b r = emit (SET_b_r b r)
res b r = emit (RES_b_r b r)

bitHL, setHL, resHL :: Int -> Asm ()
bitHL b = emit (BIT_b_HL b)
setHL b = emit (SET_b_HL b)
resHL b = emit (RES_b_HL b)

bitIX, setIX, resIX :: Int -> Int8 -> Asm ()
bitIX b d = emit (BIT_b_IXd b d)
setIX b d = emit (SET_b_IXd b d)
resIX b d = emit (RES_b_IXd b d)

bitIY, setIY, resIY :: Int -> Int8 -> Asm ()
bitIY b d = emit (BIT_b_IYd b d)
setIY b d = emit (SET_b_IYd b d)
resIY b d = emit (RES_b_IYd b d)

-- ---------------------------------------------------------------------------
-- Jumps
-- ---------------------------------------------------------------------------

jp :: AddrExpr -> Asm ()
jp e = emit (JP e)

jpn :: Word16 -> Asm ()
jpn n = emit (JP (Lit n))

jp_cc :: Condition -> AddrExpr -> Asm ()
jp_cc c e = emit (JP_cc c e)

jpHL, jpIX, jpIY :: Asm ()
jpHL = emit JP_HL
jpIX = emit JP_IX
jpIY = emit JP_IY

jr :: AddrExpr -> Asm ()
jr e = emit (JR e)

jr_cc :: Condition -> AddrExpr -> Asm ()
jr_cc c e = emit (JR_cc c e)

djnz :: AddrExpr -> Asm ()
djnz e = emit (DJNZ e)

-- ---------------------------------------------------------------------------
-- Calls / returns
-- ---------------------------------------------------------------------------

call :: AddrExpr -> Asm ()
call e = emit (CALL e)

call_cc :: Condition -> AddrExpr -> Asm ()
call_cc c e = emit (CALL_cc c e)

ret :: Asm ()
ret = emit RET

ret_cc :: Condition -> Asm ()
ret_cc c = emit (RET_cc c)

rst :: RstTarget -> Asm ()
rst t = emit (RST t)

-- ---------------------------------------------------------------------------
-- I/O
-- ---------------------------------------------------------------------------

inA :: Word8 -> Asm ()
inA n = emit (IN_A_n n)

inC :: Reg8 -> Asm ()
inC r = emit (IN_r_C r)

outA :: Word8 -> Asm ()
outA n = emit (OUT_n_A n)

outC :: Reg8 -> Asm ()
outC r = emit (OUT_C_r r)

ini, ind, inir, indr :: Asm ()
ini  = emit INI
ind  = emit IND
inir = emit INIR
indr = emit INDR

outi, outd, otir, otdr :: Asm ()
outi = emit OUTI
outd = emit OUTD
otir = emit OTIR
otdr = emit OTDR

-- ---------------------------------------------------------------------------
-- Block operations
-- ---------------------------------------------------------------------------

ldi_, ldd_, ldir_, lddr_ :: Asm ()
ldi_  = emit LDI
ldd_  = emit LDD
ldir_ = emit LDIR
lddr_ = emit LDDR

cpi_, cpd_, cpir_, cpdr_ :: Asm ()
cpi_  = emit CPI
cpd_  = emit CPD
cpir_ = emit CPIR
cpdr_ = emit CPDR
