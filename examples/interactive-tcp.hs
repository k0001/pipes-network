{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Exception                (throwIO)
import           Control.Applicative
import           Control.Monad
import           Control.Monad.Trans.Class        (lift)
import           Control.Proxy                    ((>->))
import qualified Control.Proxy                    as P
import qualified Control.Proxy.Trans.State        as PS
import qualified Control.Proxy.Trans.Reader       as PR
import           Control.Proxy.Network.TCP        (ServerSettings (..))
import           Control.Proxy.Network.TCP.Simple (Application, runServer)
import qualified Control.Proxy.Safe               as P
import qualified Data.ByteString.Char8            as B8
import           Data.Monoid                      ((<>))
import qualified Text.Parsec                      as TP
import qualified Text.Parsec.ByteString           as TP (Parser)
import qualified Network.Socket                   as NS (SockAddr)


main :: IO ()
main = do
  putStrLn "[OK] TCP server listening on 127.0.0.1:9999"
  runServer (ServerSettings (Just "127.0.0.1") 9999) interactive


-- XXX StateP should really be StateT. And maybe even ReaderP should be ReaderT
type InteractiveP p = PR.ReaderP NS.SockAddr (PS.StateP [(Int, (String, Int))] p)

interactive :: Application P.ProxyFast ()
interactive (addr, src, dst) = do
  let saddr = show addr
  putStrLn $ "[OK] Starting interactive session with " ++ saddr

  let firstTimeP = welcomeP (show addr) >=> usageP
      interactD  = (P.mapP . P.mapP) src >-> linesD >-> parseInputD >-> handleInputD
      session    = (firstTimeP >=> interactD) >-> (P.mapP . P.mapP) dst

  eio <- P.trySafeIO . P.runProxy . P.runEitherK . P.tryK
                     . PS.evalStateK [] . PR.runReaderK addr
                     $ session
  case eio of
    Left e  -> do
      putStrLn $ "[ERR] Failure in interactive session with " ++ saddr
      throwIO e
    Right _ -> do
      putStrLn $ "[OK] Closing interactive session with " ++ saddr
      return ()



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


-- | Parse proper input flowing downstream into a 'Request'.
parseInputD
  :: P.Proxy p
  => () -> P.Pipe p B8.ByteString (Either B8.ByteString Request) IO r
parseInputD = P.runIdentityK . P.foreverK $ \() -> do
  line <- P.request ()
  let (line',_) = B8.breakSubstring "\r\n" line
  case TP.parse parseRequest "" line' of
    Left _  -> P.respond $ Left line'
    Right r -> P.respond $ Right r

handleInputD :: P.Proxy p => () -> P.Pipe (InteractiveP p) (Either B8.ByteString Request) B8.ByteString IO ()
handleInputD () = loop where
  loop = do
    er <- P.request ()
    addr <- PR.ask
    case er of
      Left _  -> do
        lift . putStrLn $ "[INFO] Bad request from " <> show addr
        P.respond $ "| Bad request. See HELP for usage instructions.\r\n"
        loop
      Right r -> do
        lift . putStrLn $ "[INFO] Request from " <> show addr <> ": " <> show r
        let p = const (P.respond r) >-> runRequestD
        -- XXX We should really use StateT instead of StateP, but either
        -- pipes-safe doesn't seem to handle non-IO base monads yet or I'm
        -- missing something, so we perform this state preserving magic. Sorry.
        s <- P.liftP PS.get
        (_,s') <- PS.runStateP s . PR.runReaderP addr $ p ()
        P.liftP $ PS.put s'
        case r of
          Exit -> return ()
          _    -> loop

-- | Run a 'Request' flowing downstream. Send results downstream, if any.
runRequestD :: P.Proxy p => () -> P.Pipe (InteractiveP p) Request B8.ByteString IO ()
runRequestD () = do
    r <- P.request ()
    case r of
      Exit -> P.respond "| Bye.\r\n"
      Help -> usageP ()
      Connect h p -> do
        connId <- addConnection h p
        P.respond $ "| Added connection ID " <> B8.pack (show connId)
                    <> " to " <> B8.pack (show (h, p)) <> "\r\n"
        error "TODO"
      Disconnect connId -> do
        remConnection connId
        P.respond $ "| Removed connection ID " <> B8.pack (show connId) <> "\r\n"
        error "TODO"
      Connections -> do
        conns <- P.liftP PS.get
        P.respond $ "| Connections [(ID, (IPv4, PORT-NUMBER))]:\r\n|   "
                    <> B8.pack (show conns) <> "\r\n"
      Send connId line -> do
        P.respond $ "| Sending to connection ID " <> B8.pack (show connId) <> "\r\n"
        error "TODO"
  where
    addConnection host port = P.liftP $ do
      conns <- PS.get
      case conns of
        []    -> PS.put [(1, (host, port))] >> return 1
        (x:_) -> do let connId = fst x + 1
                    PS.put $ (connId, (host, port)):conns
                    return connId
    remConnection connId = P.liftP . PS.modify $ \conns ->
      filter ((/=connId) . fst) conns -- meh.

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

