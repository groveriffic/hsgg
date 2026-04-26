{-# LANGUAGE OverloadedStrings #-}
module Emulicious.DAP
  ( DAPClient
  , connect
  , disconnect
  , sendRequest
  , waitForEvent
  , waitForResponse
  , readMemory
  , writeMemory
  , pauseExecution
  , continueExecution
  , evaluate
  , initialize
  , launch
  ) where

import           Data.IORef
import           Data.Aeson             (Value (..), object, (.=), encode, decode)
import qualified Data.Aeson.Key         as Key
import qualified Data.Aeson.KeyMap      as KM
import qualified Data.ByteString        as BS
import qualified Data.ByteString.Lazy   as LBS
import qualified Data.ByteString.Char8  as BC8
import           Data.Foldable          (toList)
import           Data.List              (find)
import qualified Data.ByteString.Base64 as B64
import           Data.Word              (Word8, Word16)
import           Numeric                (readHex, showHex)
import           Network.Socket         (Socket, AddrInfo (..), getAddrInfo,
                                         defaultHints, SocketType (..),
                                         defaultProtocol, socket)
import qualified Network.Socket         as NS
import           Network.Socket.ByteString (recv, sendAll)
import           Data.Text              (Text)
import qualified Data.Text              as T
import           System.IO              (hPutStrLn, stderr)

data DAPClient = DAPClient
  { clientSocket :: Socket
  , clientSeq    :: IORef Int
  , clientRawBuf :: IORef BS.ByteString
  , clientMsgBuf :: IORef [Value]
  }

connect :: Int -> IO DAPClient
connect port = do
  addr:_ <- getAddrInfo
              (Just defaultHints { addrSocketType = Stream })
              (Just "127.0.0.1")
              (Just (show port))
  sock <- socket (addrFamily addr) Stream defaultProtocol
  NS.connect sock (addrAddress addr)
  seqRef <- newIORef 1
  rawRef <- newIORef BS.empty
  msgRef <- newIORef []
  pure (DAPClient sock seqRef rawRef msgRef)

disconnect :: DAPClient -> IO ()
disconnect client = do
  seq_ <- nextSeq client
  let msg = object [ "seq"       .= seq_
                   , "type"      .= ("request" :: Text)
                   , "command"   .= ("disconnect" :: Text)
                   , "arguments" .= object ["terminateDebuggee" .= True] ]
  sendFrame (clientSocket client) msg
  NS.close (clientSocket client)

-- ---------------------------------------------------------------------------
-- Send
-- ---------------------------------------------------------------------------

sendRequest :: DAPClient -> Text -> Value -> IO Int
sendRequest client cmd args = do
  seq_ <- nextSeq client
  let msg = object [ "seq"       .= seq_
                   , "type"      .= ("request" :: Text)
                   , "command"   .= cmd
                   , "arguments" .= args ]
  debugLog $ ">>> " <> T.unpack cmd
  sendFrame (clientSocket client) msg
  pure seq_

-- ---------------------------------------------------------------------------
-- Receive: buffered so events and responses never get dropped
-- ---------------------------------------------------------------------------

waitFor :: DAPClient -> (Value -> Bool) -> IO Value
waitFor client p = do
  buf <- readIORef (clientMsgBuf client)
  case find p buf of
    Just msg -> do
      writeIORef (clientMsgBuf client) (filter (/= msg) buf)
      pure msg
    Nothing -> do
      msg <- readOneFrame client
      debugLog $ "<<< " <> describeMsg msg
      modifyIORef' (clientMsgBuf client) (++ [msg])
      waitFor client p

waitForEvent :: DAPClient -> Text -> IO Value
waitForEvent client eventName =
  waitFor client (\m -> msgType m == "event" && msgEvent m == eventName)

waitForResponse :: DAPClient -> Int -> IO Value
waitForResponse client reqSeq =
  waitFor client (\m -> msgType m == "response" && msgRequestSeq m == reqSeq)

-- ---------------------------------------------------------------------------
-- High-level operations
-- ---------------------------------------------------------------------------

initialize :: DAPClient -> IO ()
initialize client = do
  seq_ <- sendRequest client "initialize" $ object
    [ "clientID"                 .= ("hsgg-test" :: Text)
    , "adapterID"                .= ("emulicious" :: Text)
    , "linesStartAt1"            .= True
    , "columnsStartAt1"          .= True
    , "supportsMemoryReferences" .= True
    ]
  _ <- waitForResponse client seq_
  pure ()

launch :: DAPClient -> FilePath -> IO ()
launch client romPath = do
  seq_ <- sendRequest client "launch" $ object
    [ "program"     .= romPath
    , "stopOnEntry" .= False
    ]
  _ <- waitForResponse client seq_
  pure ()

pauseExecution :: DAPClient -> IO Value
pauseExecution client = do
  seq_ <- sendRequest client "pause" $ object ["threadId" .= (1 :: Int)]
  _ <- waitForResponse client seq_
  waitForEvent client "stopped"

-- | Resume execution after a pause. Returns once the adapter
-- acknowledges the request.
continueExecution :: DAPClient -> IO ()
continueExecution client = do
  seq_ <- sendRequest client "continue" $ object ["threadId" .= (1 :: Int)]
  _ <- waitForResponse client seq_
  pure ()

-- | Evaluate an expression and return the result string.
evaluate :: DAPClient -> Text -> IO Text
evaluate client expr = do
  seq_ <- sendRequest client "evaluate" $ object
    [ "expression" .= expr
    , "frameId"    .= (0 :: Int)
    , "context"    .= ("watch" :: Text)
    ]
  resp <- waitForResponse client seq_
  case do { Object body <- getField resp "body"
           ; String r   <- KM.lookup (Key.fromText "result") body
           ; pure r } of
    Just r  -> pure r
    Nothing -> fail $ "evaluate: no result for " <> T.unpack expr

-- | Write @bytes@ starting at @addr@.
writeMemory :: DAPClient -> Word16 -> BS.ByteString -> IO ()
writeMemory client addr bytes = do
  let memRef = T.pack $ "0x" <> showHex addr ""
      encoded = B64.encode bytes
  seq_ <- sendRequest client "writeMemory" $ object
    [ "memoryReference" .= memRef
    , "data"            .= decodeUtf8 encoded
    ]
  _ <- waitForResponse client seq_
  pure ()
  where
    decodeUtf8 = T.pack . BC8.unpack

-- | Read @count@ bytes starting at @addr@.
-- Uses evaluate → variables to read one byte at a time.
readMemory :: DAPClient -> Word16 -> Int -> IO BS.ByteString
readMemory client startAddr count =
  BS.pack <$> mapM readByte [0 .. count - 1]
  where
    readByte offset = do
      let addr = startAddr + fromIntegral offset
          expr = "0x" <> T.pack (showHex addr "")
      vref <- evalVarRef client expr
      readFirstByte client vref

-- | Evaluate an expression and return its variablesReference.
evalVarRef :: DAPClient -> Text -> IO Int
evalVarRef client expr = do
  seq_ <- sendRequest client "evaluate" $ object
    [ "expression" .= expr
    , "frameId"    .= (0 :: Int)
    , "context"    .= ("watch" :: Text)
    ]
  resp <- waitForResponse client seq_
  case do { Object body <- getField resp "body"
           ; Number n   <- KM.lookup (Key.fromText "variablesReference") body
           ; pure (round n :: Int) } of
    Just r  -> pure r
    Nothing -> fail $ "evalVarRef: no variablesReference for " <> T.unpack expr

-- | Get the first byte variable from a variables response.
readFirstByte :: DAPClient -> Int -> IO Word8
readFirstByte client vref = do
  seq_ <- sendRequest client "variables" $ object
    [ "variablesReference" .= vref ]
  resp <- waitForResponse client seq_
  case do
    Object body <- getField resp "body"
    Array vars  <- KM.lookup (Key.fromText "variables") body
    v           <- case toList vars of { (x:_) -> Just x; [] -> Nothing }
    Object vm   <- pure v
    String val  <- KM.lookup (Key.fromText "value") vm
    -- Emulicious returns values as "$HH" (hex with dollar-sign prefix)
    pure val of
    Just val -> parseDollarHex val
    Nothing  -> fail "readFirstByte: could not extract byte value"

parseDollarHex :: Text -> IO Word8
parseDollarHex t = case T.uncons t of
  Just ('$', hex) ->
    case readHex (T.unpack hex) of
      [(n, "")] -> pure (fromIntegral (n :: Int))
      _         -> fail $ "parseDollarHex: bad hex value: " <> T.unpack t
  _ -> fail $ "parseDollarHex: expected $HH, got: " <> T.unpack t

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

sendFrame :: Socket -> Value -> IO ()
sendFrame sock val = do
  let body   = LBS.toStrict (encode val)
      header = BC8.pack ("Content-Length: " <> show (BS.length body) <> "\r\n\r\n")
  sendAll sock (header <> body)

readOneFrame :: DAPClient -> IO Value
readOneFrame client = do
  buf0 <- readIORef (clientRawBuf client)
  buf1 <- fillUntilSep client buf0
  let (headerBytes, rest) = splitOnSep buf1
  let contentLen = parseContentLength headerBytes
  buf2 <- fillUntilLen client rest contentLen
  let (body, remaining) = BS.splitAt contentLen buf2
  writeIORef (clientRawBuf client) remaining
  case decode (LBS.fromStrict body) of
    Just v  -> pure v
    Nothing -> fail $ "DAP: failed to decode JSON: " <> BC8.unpack body

nextSeq :: DAPClient -> IO Int
nextSeq client = atomicModifyIORef' (clientSeq client) (\n -> (n+1, n))

fillUntilSep :: DAPClient -> BS.ByteString -> IO BS.ByteString
fillUntilSep client buf
  | hasSep buf = pure buf
  | otherwise  = do
      chunk <- recv (clientSocket client) 4096
      if BS.null chunk
        then fail "DAP: connection closed unexpectedly"
        else fillUntilSep client (buf <> chunk)

fillUntilLen :: DAPClient -> BS.ByteString -> Int -> IO BS.ByteString
fillUntilLen client buf needed
  | BS.length buf >= needed = pure buf
  | otherwise = do
      chunk <- recv (clientSocket client) 4096
      if BS.null chunk
        then fail "DAP: connection closed unexpectedly"
        else fillUntilLen client (buf <> chunk) needed

sep :: BS.ByteString
sep = "\r\n\r\n"

hasSep :: BS.ByteString -> Bool
hasSep = BS.isInfixOf sep

splitOnSep :: BS.ByteString -> (BS.ByteString, BS.ByteString)
splitOnSep bs =
  case BS.breakSubstring sep bs of
    (h, t) -> (h, BS.drop (BS.length sep) t)

parseContentLength :: BS.ByteString -> Int
parseContentLength headers =
  case filter (BC8.isPrefixOf "Content-Length:") (BC8.lines headers) of
    (line:_) -> read . BC8.unpack . BC8.strip . BC8.drop 15 $ line
    []       -> error "DAP: no Content-Length header"

getField :: Value -> Text -> Maybe Value
getField (Object km) k = KM.lookup (Key.fromText k) km
getField _           _ = Nothing

msgType :: Value -> Text
msgType v = case getField v "type" of
  Just (String t) -> t
  _               -> ""

msgEvent :: Value -> Text
msgEvent v = case getField v "event" of
  Just (String t) -> t
  _               -> ""

msgCommand :: Value -> Text
msgCommand v = case getField v "command" of
  Just (String t) -> t
  _               -> ""

msgRequestSeq :: Value -> Int
msgRequestSeq v = case getField v "request_seq" of
  Just (Number n) -> round n
  _               -> -1

describeMsg :: Value -> String
describeMsg v = case msgType v of
  "event"    -> "event(" <> T.unpack (msgEvent v) <> ")"
  "response" -> "response(" <> T.unpack (msgCommand v) <> " seq=" <> show (msgRequestSeq v) <> ")"
  t          -> T.unpack t

debugLog :: String -> IO ()
debugLog _ = pure ()  -- set to `hPutStrLn stderr $ "[DAP] " <> msg` for tracing
