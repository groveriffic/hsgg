module Z80.Linker
  ( LinkerError (..)
  , LabelMap
  , assemble
  , assembleWithSymbols
  ) where

import Data.Bits        (shiftR, (.&.))
import Data.Int         (Int8)
import Data.Map.Strict  (Map)
import qualified Data.Map.Strict  as Map
import Data.Foldable    (toList)
import Data.Sequence    (Seq)
import Data.Word        (Word8, Word16)
import qualified Data.ByteString  as BS
import qualified Data.ByteString.Builder as BB
import Data.ByteString.Builder (Builder)
import Data.Text (Text)
import qualified Data.Text as T

import Z80.Types
import Z80.Asm      (Statement (..))
import Z80.Encoder  (encode, instrSize)

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

data LinkerError
  = UndefinedLabel     Label
  | DuplicateLabel     Label
  | RelativeOutOfRange Text Int   -- label name + computed offset
  deriving (Show, Eq)

type LabelMap = Map Label Word16

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

-- | Two-pass assembly: collect labels then emit bytes.
assemble
  :: Word16           -- ^ origin address
  -> Seq Statement
  -> Either LinkerError BS.ByteString
assemble origin stmts = fst <$> assembleWithSymbols origin stmts

-- | Like 'assemble' but also returns the resolved label→address map.
assembleWithSymbols
  :: Word16
  -> Seq Statement
  -> Either LinkerError (BS.ByteString, LabelMap)
assembleWithSymbols origin stmts = do
  lmap  <- buildLabelMap origin stmts
  bytes <- emitBytes lmap origin stmts
  pure (BS.toStrict (BB.toLazyByteString bytes), lmap)

-- ---------------------------------------------------------------------------
-- Pass 1: build label map
-- ---------------------------------------------------------------------------

buildLabelMap :: Word16 -> Seq Statement -> Either LinkerError LabelMap
buildLabelMap origin stmts = go origin Map.empty (toList stmts)
  where
    go _ lmap [] = Right lmap
    go pc lmap (s : rest) = case s of
      DeclLabel lbl
        | Map.member lbl lmap -> Left (DuplicateLabel lbl)
        | otherwise            -> go pc (Map.insert lbl pc lmap) rest
      ORG addr -> go addr lmap rest
      Instr i  -> go (pc + fromIntegral (instrSize i)) lmap rest
      DB bs    -> go (pc + fromIntegral (length bs)) lmap rest
      DW ws    -> go (pc + fromIntegral (length ws * 2)) lmap rest
      DS n _   -> go (pc + fromIntegral n) lmap rest

-- ---------------------------------------------------------------------------
-- Pass 2: emit bytes
-- ---------------------------------------------------------------------------

emitBytes :: LabelMap -> Word16 -> Seq Statement -> Either LinkerError Builder
emitBytes lmap origin stmts = go origin mempty (toList stmts)
  where
    go _ acc [] = Right acc
    go pc acc (s : rest) = case s of
      DeclLabel _ -> go pc acc rest
      ORG addr    -> go addr acc rest
      DB bs       -> go (pc + fromIntegral (length bs))
                        (acc <> foldMap BB.word8 bs) rest
      DW ws       -> do
        resolved <- mapM (resolveAddrE lmap) ws
        go (pc + fromIntegral (length ws * 2))
           (acc <> foldMap BB.word16LE resolved) rest
      DS n v      ->
        go (pc + fromIntegral n)
           (acc <> foldMap BB.word8 (replicate n v)) rest
      Instr i     -> do
        encoded <- encodeResolved lmap pc i
        go (pc + fromIntegral (length encoded))
           (acc <> foldMap BB.word8 encoded) rest

-- ---------------------------------------------------------------------------
-- Resolve an AddrExpr using the label map
-- ---------------------------------------------------------------------------

resolveAddrE :: LabelMap -> AddrExpr -> Either LinkerError Word16
resolveAddrE _    (Lit w)          = Right w
resolveAddrE lmap (LabelRef lbl)   = lookupLabel lmap lbl
resolveAddrE lmap (LabelRefLo lbl) = do
  w <- lookupLabel lmap lbl
  pure (w .&. 0x00FF)
resolveAddrE lmap (LabelRefHi lbl) = do
  w <- lookupLabel lmap lbl
  pure (w `shiftR` 8)

lookupLabel :: LabelMap -> Label -> Either LinkerError Word16
lookupLabel lmap lbl =
  maybe (Left (UndefinedLabel lbl)) Right (Map.lookup lbl lmap)

-- ---------------------------------------------------------------------------
-- Resolve address operands then encode
-- ---------------------------------------------------------------------------

encodeResolved :: LabelMap -> Word16 -> Instruction -> Either LinkerError [Word8]
encodeResolved lmap pc instr = case instr of
  -- Absolute address operands
  JP      e       -> lit1 e $ \a -> encode (JP      (Lit a))
  JP_cc c e       -> lit1 e $ \a -> encode (JP_cc c (Lit a))
  CALL    e       -> lit1 e $ \a -> encode (CALL    (Lit a))
  CALL_cc c e     -> lit1 e $ \a -> encode (CALL_cc c (Lit a))
  LD_A_nn e       -> lit1 e $ \a -> encode (LD_A_nn  (Lit a))
  LD_nn_A e       -> lit1 e $ \a -> encode (LD_nn_A  (Lit a))
  LD_HL_ind e     -> lit1 e $ \a -> encode (LD_HL_ind (Lit a))
  LD_nn_HL  e     -> lit1 e $ \a -> encode (LD_nn_HL  (Lit a))
  LD_rr_nn rr e   -> lit1 e $ \a -> encode (LD_rr_nn rr (Lit a))
  LD_rr_ind rr e  -> lit1 e $ \a -> encode (LD_rr_ind rr (Lit a))
  LD_nn_rr e rr   -> lit1 e $ \a -> encode (LD_nn_rr (Lit a) rr)

  -- Relative jumps: compute signed byte offset
  JR e            -> relJump e (addrLabel e) pc $ \off -> encode (JR    (Lit (asW16 off)))
  JR_cc c e       -> relJump e (addrLabel e) pc $ \off -> encode (JR_cc c (Lit (asW16 off)))
  DJNZ e          -> relJump e (addrLabel e) pc $ \off -> encode (DJNZ  (Lit (asW16 off)))

  -- No address operands: encode directly (resolveAddr would error on labels,
  -- but instructions without AddrExpr fields won't reach it)
  _               -> Right (encode instr)

  where
    lit1 e f = fmap f (resolveAddrE lmap e)

    relJump addrExpr mlblName curPc mkInstr = do
      target <- resolveAddrE lmap addrExpr
      let isize  = 2   -- JR / DJNZ are always 2 bytes
          nextPc = curPc + isize
          offset = fromIntegral target - fromIntegral nextPc :: Int
      if offset >= -128 && offset <= 127
        then Right (mkInstr (fromIntegral offset :: Int8))
        else Left (RelativeOutOfRange (maybe T.empty labelName mlblName) offset)

    addrLabel (LabelRef l)   = Just l
    addrLabel (LabelRefLo l) = Just l
    addrLabel (LabelRefHi l) = Just l
    addrLabel (Lit _)        = Nothing

    asW16 :: Int8 -> Word16
    asW16 = fromIntegral . (fromIntegral :: Int8 -> Word8)
