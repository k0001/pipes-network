{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind -fno-warn-missing-signatures #-}

module Main where

import           Control.Concurrent             (forkIO, threadDelay)
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
    forkIO server
    -- we sleep half second hoping that the server has started.
    threadDelay 500000
    client
  where
    server = do
      let p = P.fromListS msg1 >-> T'.serveWriteD Nothing host1p port1
      P.runSafeIO . P.runProxy .P.runEitherK $ p
    client = do
      let p = P.raiseK (T'.connectReadS Nothing 4096 host1 port1) >-> P.toListD
      (eex,out) <- P.trySafeIO . P.runWriterT . P.runProxy .P.runEitherK $ p
      case eex of
        Left ex  -> E.throw ex
        Right () -> B.concat out @=? msg1b

connectWriteToServeRead :: Assertion
connectWriteToServeRead = do
    forkIO server
    -- we sleep half second hoping that the server has started.
    threadDelay 500000
    client
  where
    client = do
       let p = P.fromListS msg1 >-> T'.connectWriteD Nothing host1 port1
       P.runSafeIO . P.runProxy .P.runEitherK $ p
    server = do
      let p = P.raiseK (T'.serveReadS Nothing 4096 host1p port1) >-> P.toListD
      (eex,out) <- P.trySafeIO . P.runWriterT . P.runProxy .P.runEitherK $ p
      case eex of
        Left ex  -> E.throw ex
        Right () -> B.concat out @=? msg1b

tests :: [Test]
tests =
  [ testGroup "Safe TCP"
    [ testGroup "{serve,connect}{WriteD,ReadS}"
      [ testCase "serveWriteToConnectWrite" serveWriteToConnectWrite
      , testCase "connectWriteToServeRead"  connectWriteToServeRead
      ]
    ]
  ]

main :: IO ()
main = NS.withSocketsDo $ defaultMain tests