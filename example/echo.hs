import           Control.Proxy
import           Control.Proxy.Network
import qualified Data.ByteString.Char8 as B8
import           Data.Char (toUpper)


main = do
  putStrLn "Listening on 127.0.0.1, TCP port 9999..."

  runTCPServer settings $ \(src, dst) -> do
    runProxy $ src >-> printD >-> mapD (B8.map toUpper) >-> dst

  where
    settings = ServerSettings
                 { serverPort = 9999
                 , serverHost = Just "127.0.0.1"
                 }
