import           Control.Proxy
import           Control.Proxy.Network.TCP.Simple
import qualified Data.ByteString.Char8 as B8
import           Data.Char (toUpper)


main :: IO ()
main = do
  let settings = ServerSettings (Just "127.0.0.1") 9999
  runServer settings $ \(addr, src, dst) -> do
    putStrLn $ "Listening on " ++ show addr
    runProxy $ src >-> printD >-> mapD (B8.map toUpper) >-> dst

