{-# LANGUAGE FlexibleInstances #-}
-- | Modular error reporting and common functions
module Util where
import Control.Monad.Error
import Control.Monad.Identity

-- | a compile error
-- 
-- * corresponding part of program (ex.: frontend, core)
--
-- * position (inline)
--
-- * error descriptipn(multiple line)
data CompileError=CompileError String String String

instance Show CompileError where
    show (CompileError m p d)=m++":"++p++"\n"++d


runProcessIO :: ProcessIO () -> IO ()
runProcessIO f=runErrorT f >>=
    either (putStr . unlines . map show) return

runProcess :: Process a -> Either [CompileError] a
runProcess=runIdentity . runErrorT


unwrapIO :: ProcessIO a -> IO (Process a)
unwrapIO=liftM (ErrorT . Identity) . runErrorT




type ProcessIO a=ErrorT [CompileError] IO a
type Process a=ErrorT [CompileError] Identity a

wrapP :: IO a -> ProcessIO a
wrapP=ErrorT . liftM Right

wrapIO :: Process a -> ProcessIO a
wrapIO =ErrorT . return . runIdentity . runErrorT


instance Error [CompileError] where
    noMsg=[]
    

-- note for future me: Arrow vs. Monad
--    Suppose each process can return either error or result.
--   Parallel execution of such processes can be written as:
--    (a -> m b) -> [a] -> m [b]  : Monadic form
--    w a b -> w [a] [b] : Arrow form
-- 
-- How to decide on one?
--    If you can write [m b] -> m [b] , then use Monad(Plus).
--   Otherwise use Arrow.


-- | a b c ... z aa ab ac ... az ba ...
-- avoid CAF.
stringSeq :: String -> [String]
stringSeq prefix=tail $ map ((prefix++) . reverse) $ iterate stringInc []

stringInc :: String -> String
stringInc []="a"
stringInc ('z':xs)='a':stringInc xs
stringInc (x:xs)=succ x:xs

-- | usage
--
-- > change1 "XYZ" "abc"
--
-- evaluates to
--
-- > ["Xbc","aYc","abZ"]
change1 :: [a] -> [a] -> [[a]]
change1 (x:xs) (y:ys)=(x:ys):map (y:) (change1 xs ys)
change1 _ _=[]
