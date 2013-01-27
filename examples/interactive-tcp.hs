{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Proxy                    ((>->))
import qualified Control.Proxy                    as P
import           Control.Proxy.Network.TCP        (ServerSettings (..))
import           Control.Proxy.Network.TCP.Simple (Application, runServer)
import qualified Control.Proxy.Safe               as P
import qualified Data.ByteString.Char8            as B8
import           Data.Monoid                      ((<>))
import qualified Text.Parsec                      as TP
import qualified Text.Parsec.ByteString           as TP (Parser)


main :: IO ()
main = do
  putStrLn "TCP server listening on 127.0.0.1:9999"
  runServer (ServerSettings (Just "127.0.0.1") 9999) interactive



interactive :: Application P.ProxyFast ()
interactive (addr, src, dst) = do
  putStrLn $ "Incomming connection: " ++ show addr

  let firstTimeP = welcomeP (show addr) >=> usageP
      interactD = src >-> linesD >-> parseRequestD >-> runRequestD
      fullProxy = (firstTimeP >=> interactD) >-> dst

  P.runSafeIO . P.runProxy . P.runEitherK $ P.tryK fullProxy


--------------------------------------------------------------------------------
-- Client requests interpreter

type ConnectionId = Int

data Request
  = Exit
  | Help
  | Connect String Int
  | Disconnect ConnectionId
  | Connections
  | Send ConnectionId String
  deriving (Show, Eq)

-- | Parse input flowing downstream into either a 'Request', or an error message
parseRequestD
  :: P.Proxy p
  => () -> P.Pipe p B8.ByteString (Either B8.ByteString Request) IO r
parseRequestD = P.runIdentityK . P.foreverK $ \() -> do
  line <- P.request ()
  let (line',_) = B8.breakSubstring "\r\n" line
  case TP.parse parseRequest "" line' of
    Left _ -> do
      P.respond $ Left "Bad input. Try again."
    Right op -> do
      lift . putStrLn $ "Good input " <> show op
      P.respond $ Right op


-- | Run a 'Request' flowing downstream. Send results downstream, if any.
runRequestD
  :: P.Proxy p
  => () -> P.Pipe p (Either B8.ByteString Request) B8.ByteString IO r
runRequestD = P.runIdentityK . P.foreverK $ \() -> do
  eop <- P.request ()
  -- TODO: DO SOMETHING
  case eop of
    Left e   -> P.respond $ "ERR: " <> e <> "\r\n"
    Right op -> do
      P.respond $ "OK: " <> (B8.pack $ show op) <> "\r\n"
      case op of
        Help -> usageP ()
        _ -> undefined


--------------------------------------------------------------------------------
-- Mostly boring stuff below here.

-- | Send a greeting message to @who@ downstream.
welcomeP :: (Monad m, P.Proxy p) => String -> () -> p a' a () B8.ByteString m ()
welcomeP who () = P.respond $
   "| Welcome to the non-magical TCP client, " <> B8.pack who <> ".\r\n"

-- | Send a usage instructions downstream.
usageP :: (Monad m, P.Proxy p) => () -> p a' a () B8.ByteString m ()
usageP () = P.respond usageMsg

usageMsg :: B8.ByteString
usageMsg =
   "| Enter one of the following commands:\r\n\
   \|   HELP\r\n\
   \|     Show this message.\r\n\
   \|   CONNECT <IPv4> <PORT-NUMBER>\r\n\
   \|     Establish a TCP connection to the given TCP server.\r\n\
   \|     The ID of the new connection is shown on success.\r\n\
   \|   DISCONNET <ID>\r\n\
   \|     Close a the established TCP connection identified by <ID>.\r\n\
   \|   CONNECTIONS\r\n\
   \|     Shows all established TCP connections and their <ID>s.\r\n\
   \|   SEND <ID> <LINE>\r\n\
   \|     Sends <LINE> followed by \\r\\n to the established TCP\r\n\
   \|     connection identified by <ID>. Any response is shown.\r\n\
   \|   EXIT\r\n\
   \|     Exit this interactive session.\r\n"


-- | Split raw input flowing downstream into individual lines.
--
-- Probably not an efficient implementation, and maybe even wrong.
linesD :: P.Proxy p => () -> P.Pipe p B8.ByteString B8.ByteString IO r
linesD = P.runIdentityK (go B8.empty) where
  go buf () = P.request () >>= use . (buf <>)
  use buf = do
    let (p,s) = B8.breakSubstring "\r\n" buf
    case (B8.length p, B8.length s) of
      (_,0) -> go p () -- no more input in buffer, request more
      (_,2) -> P.respond p >> go B8.empty () -- 2 suffix chars are \r\n
      (0,_) -> P.respond B8.empty >> use (B8.drop 2 s) -- leading newline
      (_,_) -> P.respond p >> use (B8.drop 2 s) -- 2 first suffix chars are \r\n


-------------------------------------------------------------------------------
-- Input parsing

parseRequest :: TP.Parser Request
parseRequest = TP.choice allt <* TP.eof
  where
    allt        = [exit, help, TP.try connect, disconnect, connections, send]
    exit        = TP.string "EXIT" *> pure Exit
    help        = TP.string "HELP" *> pure Help
    connect     = TP.string "CONNECT " *> (uncurry Connect <$> parseHostAndPort)
    disconnect  = TP.string "DISCONNECT " *> (Disconnect <$> parseConnectionId)
    connections = TP.string "CONNECTIONS" *> pure Connections
    send        = TP.string "SEND " *> sendBody
    sendBody    = Send <$> (parseConnectionId <* TP.space)
                       <*> (TP.manyTill TP.anyChar TP.eof)

parseConnectionId :: TP.Parser ConnectionId
parseConnectionId = read <$> TP.many1 TP.digit :: TP.Parser ConnectionId

parseHostAndPort :: TP.Parser (String, Int)
parseHostAndPort = do -- Ugly code. I'll get better at using Parsec some day.
  let hostnameChar = TP.choice [TP.alphaNum, TP.char '.', TP.char '-']
  hostname <- TP.manyTill hostnameChar TP.space
  case hostname of
    [] -> mzero
    _  -> do
      port <- TP.many1 TP.digit
      case port of
        [] -> mzero
        _  -> return (hostname, read port)

