{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Z80.Asm
  ( -- * The Asm monad
    Asm
  , runAsm
    -- * Statements
  , Statement (..)
    -- * Primitives
  , emit
  , rawLabel
  , defineLabel
  , freshLabel
  , ref
  , org
  , db
  , dw
  , ds
  ) where

import Control.Monad.State.Strict
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8, Word16)

import Z80.Types

-- | A single assembler statement
data Statement
  = Instr      Instruction
  | DeclLabel  Label
  | DB         [Word8]     -- raw bytes
  | DW         [AddrExpr]  -- raw words (little-endian)
  | DS         Int Word8   -- fill N bytes with value
  | ORG        Word16      -- set assembly origin
  deriving (Show, Eq)

data AsmState = AsmState
  { stmts   :: Seq Statement
  , counter :: Int
  }

-- | The assembler monad
newtype Asm a = Asm (State AsmState a)
  deriving (Functor, Applicative, Monad)

-- | Run an Asm program and extract its statement sequence
runAsm :: Asm () -> Seq Statement
runAsm (Asm m) = stmts $ execState m (AsmState Seq.empty 0)

append :: Statement -> Asm ()
append s = Asm (modify' (\st -> st { stmts = stmts st |> s }))

-- | Emit a single instruction
emit :: Instruction -> Asm ()
emit = append . Instr

-- | Declare a label at the current position
rawLabel :: Label -> Asm ()
rawLabel = append . DeclLabel

-- | Declare a named label and return it for use as a jump target
defineLabel :: Text -> Asm Label
defineLabel name = do
  let l = Label name
  rawLabel l
  pure l

-- | Generate a unique label with the given prefix (for internal use by DSL helpers)
freshLabel :: Text -> Asm Label
freshLabel prefix = Asm $ do
  st <- get
  let n = counter st
  put st { counter = n + 1 }
  pure (Label (prefix <> T.pack (show n)))

-- | Reference a label by name (for use in operands before the label is defined)
ref :: Text -> AddrExpr
ref = LabelRef . Label

-- | Set the assembly origin address
org :: Word16 -> Asm ()
org = append . ORG

-- | Emit raw bytes
db :: [Word8] -> Asm ()
db = append . DB

-- | Emit raw 16-bit words (little-endian)
dw :: [AddrExpr] -> Asm ()
dw = append . DW

-- | Emit N copies of a byte value
ds :: Int -> Word8 -> Asm ()
ds n v = append (DS n v)
