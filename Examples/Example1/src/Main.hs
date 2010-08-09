module Main (main) where
import Control.Concurrent (threadDelay)
import qualified Ros.Std_msgs.String as S
import Ros.Node

wait n = threadDelay (1000000 * n)

publish = go 1
    where go n = Cons (wait 3 >> return (S.String (show n ++ " HA HA HA")))
                      (go (n+1))

handle (Cons m ms) = putStrLn ("roskell got "++S._data m) >> handle ms

main = runNode "/roskell" $ do advertiseIO "/MyMessage" publish
                               chat <- subscribe "/chat"
                               runHandler (handle chat)