{-# LANGUAGE OverloadedStrings #-}
module Z80.ControlFlow
  ( invertCond
  , ifAsm
  , ifElseAsm
  , whileAsm
  , doWhileAsm
  , forAsm
  ) where

import Data.Word (Word8)

import Z80.Types
import Z80.Asm   (Asm, freshLabel, rawLabel)
import Z80.Opcodes (jp, jp_cc, djnz, ldi)

invertCond :: Condition -> Condition
invertCond NZ = Z;  invertCond Z  = NZ
invertCond NC = CF; invertCond CF = NC
invertCond PO = PE; invertCond PE = PO
invertCond P  = M;  invertCond M  = P

-- | Emit a conditional block. @cond@ is the condition that must hold for the
-- body to execute (the jump is taken when the condition is FALSE).
-- The caller must set flags before calling ifAsm.
ifAsm :: Condition -> Asm () -> Asm ()
ifAsm cond body = do
  endLbl <- freshLabel "_ifEnd"
  jp_cc (invertCond cond) (LabelRef endLbl)
  body
  rawLabel endLbl

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

-- | Loop while flags satisfy @cond@. The condition expression (flag-setting
-- code) is re-evaluated each iteration.
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

doWhileAsm :: Condition -> Asm () -> Asm () -> Asm ()
doWhileAsm cond body condExpr = do
  topLbl <- freshLabel "_doTop"
  rawLabel topLbl
  body
  condExpr
  jp_cc cond (LabelRef topLbl)

-- | Counted loop using DJNZ. Loads B with @count@; body runs @count@ times.
-- Destroys B.
forAsm :: Word8 -> Asm () -> Asm ()
forAsm count body = do
  lbl <- freshLabel "_forLoop"
  ldi B count
  rawLabel lbl
  body
  djnz (LabelRef lbl)
