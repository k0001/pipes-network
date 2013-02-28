{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent             (forkIO)
import           Control.Concurrent.MVar        (newEmptyMVar, putMVar, takeMVar)
import qualified Control.Exception       as E
import qualified Data.ByteString.Char8   as B
import qualified Network.Socket          as NS
import           Test.Framework                 (Test, defaultMain, testGroup)
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit                     (Assertion, (@=?))
import           Control.Proxy           ((>->))
import qualified Control.Proxy           as P
import qualified Control.Proxy.Safe      as P
import qualified Control.Proxy.TCP       as T
import qualified Control.Proxy.TCP.Safe  as T'

host1  = "127.0.0.1"   :: String
host1p = T.Host host1  :: T.HostPreference
port1  = "14000"       :: NS.ServiceName
msg1   = take 1000 $ cycle ["Hello ", "World\r\n"] :: [B.ByteString]
msg1b  = B.concat msg1 :: B.ByteString

serveWriteToConnectWrite :: Assertion
serveWriteToConnectWrite = do
    mv1 <- newEmptyMVar
    let pserver =
          P.fromListS msg1
          >-> \b' -> do P.tryIO $ putMVar mv1 ()
                        T'.serveWriteD Nothing host1p port1 b'
        pclient =
          P.raiseK (T'.connectReadS Nothing 4096 host1 port1)
          >-> \b' -> do P.raise . P.tryIO $ takeMVar mv1
                        P.toListD b'
    forkIO . P.runSafeIO . P.runProxy .P.runEitherK $ pserver
    (eex,out) <- P.trySafeIO . P.runWriterT . P.runProxy .P.runEitherK $ pclient
    case eex of
      Left ex  -> E.throw ex
      Right () -> B.concat out @=? msg1b

connectWriteToServeRead :: Assertion
connectWriteToServeRead = do
    mv1 <- newEmptyMVar
    let pserver =
          P.raiseK (T'.serveReadS Nothing 4096 host1p port1)
          >-> \b' -> do P.raise . P.tryIO $ putMVar mv1 ()
                        P.toListD b'
        pclient =
          P.fromListS msg1
          >-> \b' -> do P.tryIO $ takeMVar mv1
                        T'.connectWriteD Nothing host1 port1 b'
    forkIO . P.runSafeIO . P.runProxy .P.runEitherK $ pclient
    (eex,out) <- P.trySafeIO . P.runWriterT . P.runProxy .P.runEitherK $ pserver
    case eex of
      Left ex  -> E.throw ex
      Right () -> B.concat out @=? msg1b

tests :: [Test]
tests =
  [ testGroup "Safe TCP"
    [ testGroup "{serve,connect}{WriteD,ReadS}"
      [ testCase "serveWriteToConnectWrite" serveWriteToConnectWrite
      , testCase "connectWriteToServeRead" connectWriteToServeRead
      ]
    ]
  ]

main :: IO ()
main = NS.withSocketsDo $ defaultMain tests