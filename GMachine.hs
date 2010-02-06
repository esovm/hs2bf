-- | GMachine
-- reference: Implementing Functional Languages: a tutorial
--
-- GC is executed every 256 allocation.
module GMachine where
import Control.Monad
import Control.Monad.State
import Data.Char
import Data.List
import Data.Maybe
import qualified Data.Map as M

import Util
import SAM


data GFCompileFlag=GFCompileFlag
    {addrSpace :: Int -- ^ bytes
    }


-- | Compile 'GMCode's to SAM
--
-- See my blog for overview of operational model.
--
-- Heap frame of size k with n-byte address:
--
-- * 1 B: size of this frame
--
-- * k B: payload
--
-- * n B: id of this frame
--
-- Heap payload:
compile :: M.Map String [GMCode] -> Process SAM
compile m
    |codeSpace>1 = error "GM->SAM: 255+ super combinator is not supported"
    |heapSpace>1 = error "GM->SAM: 2+ byte addresses are not supported"
    |otherwise   = return $ SAM (ss++hs) (lib++cmd++prc++loop)
    where
        t=M.fromList $ zip (M.keys m) [0..]
        
        -- code generation
        lib=[origin,heapNew,stackNew]
        cmd=map (compileCode t) $ nub $ concat $ M.elems m
        prc=map (uncurry compileCodeBlock) $ M.assocs m
        loop=[rootProc,setupMemory,mainLoop,eval,exec $ M.assocs t]
        
        -- layout configuration
        codeSpace=ceiling $ log (fromIntegral $ M.size m+1)/log 256
        heapSpace=1
        ss=map (("S"++) . show) [0..heapSpace-1]
        hs=["H0"]



compileCodeBlock :: String -> [GMCode] -> SProc
compileCodeBlock name cs=SProc ("!"++name) "S0" [] $ map (flip Inline [] . compileName) cs


compileName :: GMCode -> String
compileName (PushSC k)="%PushSC_"++k
compileName (Pack t n)="%Pack_"++show t++"_"++show n
compileName (Slide n) ="%Slide_"++show n
compileName (Push n)  ="%Push_"++show n

-- | Compile a single 'GMCode' to a procedure.
compileCode :: M.Map String Int -> GMCode -> SProc
compileCode m c=SProc (compileName c) "S0" [] $ case c of
    PushSC k ->
        [Inline "#origin" []
        ,Bank "H0"
        ,SAM.Alloc "addr"
        ,Inline "#heapNew" ["addr"]
        ,Clear (Memory 3),Move (Register "addr") [Memory 3]
        ,Delete "addr"
        ,Val (Memory 0) 4 -- size(size)+size(tag)+size(SC)+size(addr)
        ,Clear (Memory 1),Val (Memory 1) $ m M.! k
        ,Clear (Memory 2),Val (Memory 2) scTag
        ,Clear (Memory 4) -- new frame
        ,Bank "S0"
        ]
    Pack t n ->
        [Inline "#origin" []
        ,Bank "H0"
        ,SAM.Alloc "addr"
        ,Inline "#heapNew" ["addr"]
        ,Clear (Memory $ 3+n),Move (Register "addr") [Memory $ 3+n]
        ,Delete "addr"
        ,Val (Memory 0) $ 4+n -- size
        ,Clear (Memory 1),Val (Memory 1) structTag -- frame tag
        ,Clear (Memory 2),Val (Memory 2) t -- struct tag
        ,Clear (Memory $ 4+n) -- new frame
        ,SAM.Alloc "temp"
        ]
        ++concatMap st2heap (reverse [1..n]) -- pack struct members from back to front
        ++[SAM.Delete "temp",Bank "S0"]
        where st2heap ix=[Bank "S0",Inline "#origin" [],Inline "#stackNew" []
                         ,Locate (-1),Move (Memory 0) [Register "temp"]
                         ,Inline "#origin" [],Bank "H0",Inline "#heapNew_" []
                         ,Move (Register "temp") [Memory $ negate $ 1+ix]
                         ]
    Slide n ->
        [Inline "#origin" []
        ,Inline "#stackNew" []
        ,Locate (-1)
        ,Move (Memory 0) [Memory $ negate n]
        ]
        ++map (Clear . Memory . negate) [1..n-1]
    Push n ->
        [Inline "#origin" []
        ,Inline "#stackNew" []
        ,SAM.Alloc "temp"
        ,Move (Memory $ negate $ n+1) [Memory 0,Register "temp"]
        ,Move (Register "temp") [Memory $ negate $ n+1]
        ]

appTag=0
scTag=1
constTag=2
structTag=3
refTag=4


rootProc :: SProc
rootProc=SProc "^" "S0" []
    [Inline "%setupMemory" []
    ,Inline "%mainLoop" []
    ]


setupMemory :: SProc
setupMemory=SProc "%setupMemory" "S0" []
    [Val (Memory addr) sc
    ,Bank "H0"
    ,Val (Memory 0) 4
    ,Val (Memory 1) scTag
    ,Val (Memory 2) sc
    ,Val (Memory 3) addr -- addr
    ,Bank "S0"
    ]
    where sc=1; addr=1

mainLoop :: SProc
mainLoop=SProc "%mainLoop" "S0" []
    [SAM.Alloc "sc"
    ,Val (Register "sc") 1 -- any non-zero number will do
    ,While (Register "sc")
        [Inline "eval" []
        ,Inline "exec" []
        ]
    ]

eval :: SProc
eval=SProc "%eval" "S0" ["sc"]
    [Inline "#stack0" []
    ,SAM.Alloc "addr"
    ,Move (Memory (-1)) [Register "addr"]
    ,Inline "#stack0" []
    ,Bank "H0"
    ,Inline "#heapRef" ["addr"]
    ,Delete "addr"
    ,SAM.Alloc "tag"
    ,SAM.Alloc "temp"
    ,Move (Memory 1) [Register "temp"]
    ,Move (Register "temp") [Memory 1,Register "tag"]
    ,Dispatch (Register "tag")
        [(scTag,
            [Move (Memory 2) [Register "temp"]
            ,Move (Register "temp") [Memory 2,Register "sc"]
            ])
        ,(structTag,
            [Move (Memory 2) [Register "temp"]
            ,SAM.Alloc "stag"
            ,Move (Register "temp") [Memory 2,Register "stag"]
            ,Dispatch (Register "stag")
                [(2,[Clear (Register "sc")])] -- 0 :input 1:output 2:halt
            ,Delete "stag"
            ])
        ]
    ]

exec :: [(String,Int)] -> SProc
exec xs=SProc "%exec" "S0" ["sc"]
    [SAM.Alloc "temp"
    ,SAM.Alloc "temp2"
    ,Move (Register "sc") [Register "temp",Register "temp2"]
    ,Move (Register "temp") [Register "sc"]
    ,Delete "temp"
    ,Dispatch (Register "temp2") $ map f xs
    ,Delete "temp2"
    ]
    where f (str,n)=(n,[Inline ("!"++str) []])



-- | H0: move to a new heap allocation frame and put the id to addr from H0:0
--
-- from: head of heap frame
--
-- Memory is 0 after this (that's a consequence from the memory allocator)
heapNew :: SProc
heapNew=SProc "#heapNew" "H0" ["addr"]
    [SAM.Alloc "temp"
    ,While (Memory 0)
        [Move (Memory 0) [Register "addr"]
        ,Move (Register "addr") [Memory 0,Register "temp"]
        ,While (Register "temp")
            [Val (Register "temp") (-1)
            ,Locate 1]
        ]
    ,Move (Memory (-1)) [Register "temp",Register "addr"]
    ,Move (Register "temp") [Memory (-1)]
    ,Delete "temp"
    ,Val (Register "addr") 1
    ]

-- | H0: move to a new heap allocation frame
--
-- from: head of heap frame
--
-- Memory is 0 after this (that's a consequence from the memory allocator)
heapNew_ :: SProc
heapNew_=SProc "#heapNew_" "H0" []
    [SAM.Alloc "temp"
    ,SAM.Alloc "cnt"
    ,While (Memory 0)
        [Move (Memory 0) [Register "temp"]
        ,Move (Register "temp") [Memory 0,Register "cnt"]
        ,While (Register "cnt")
            [Val (Register "cnt") (-1)
            ,Locate 1]
        ]
    ,Delete "temp"
    ,Delete "cnt"
    ]

-- | H0: heap reference
--
-- from: head of heap frame 0
--
-- to: head of heap frame addr
--
-- addr will be 0 after this
heapRef :: SProc
heapRef=SProc "#heapRef" "H0" ["addr"]
    [Val (Register "addr") (-1)
    ,While (Register "addr")
        [SAM.Alloc "temp"
        ,SAM.Alloc "cnt"
        ,Move (Memory 0) [Register "temp"]
        ,Move (Register "temp") [Memory 0,Register "cnt"]
        ,Delete "temp"
        ,While (Register "cnt")
            [Val (Register "cnt") (-1)
            ,Locate 1
            ]
        ,Delete "cnt"
        ]
    ]

-- | S0: from anywhere /before stack top/. Only use this when the condition is known to be met.
stackNew :: SProc
stackNew=SProc "#stackNew" "S0" []
    [While (Memory 0) [Locate 1]]

-- | S0: goto 0 from anywhere
origin :: SProc
origin=SProc "#origin" "S0" []
    [While (Memory 0) [Locate (-1)]]






data GMCode
    =Slide Int -- ^ pop 1st...nth items
    |Alloc Int
    |Update Int -- ^ \[n\]:=Ind &\[0\] and pop 1
    |Pop Int -- ^ remove n items
    |MkApp
    |Eval
    |Push Int
    |PushSC String
    |PushByte Int
    |Pack Int Int
    |Casejump [(Int,GMCode)]
    |Split Int
    |MkByte Int
    deriving(Show,Eq,Ord)


pprintGM :: M.Map String [GMCode] -> String
pprintGM=compileSB 0 . intersperse SNewline . map (uncurry pprintGMF) . M.assocs

pprintGMF :: String -> [GMCode] -> StrBlock
pprintGMF name cs=SBlock
    [SPrim name,SPrim ":",SIndent,SNewline
    ,SBlock $ map (\x->SBlock [SPrim $ show x,SNewline]) cs]


-- | G-machine state for use in 'interpretGM'
type GMS=State GMInternal
type GMST m a=StateT GMInternal m a

data GMInternal=GMInternal{stack::Stack,heap::Heap} deriving(Show)
data GMNode
    =App Address Address
    |Ref Address
    |Const Int
    |Struct Int [Address]
    |Combinator String
    deriving(Show)

type Stack=[Address]
type Heap=M.Map Address GMNode

newtype Address=Address Int deriving(Show,Eq,Ord)





interpretGM :: M.Map String [GMCode] -> IO ()
interpretGM fs=evalStateT (exec []) (makeEmptySt "main")
    where exec code=aux code >>= maybe (return ()) (exec . (fs M.!))

makeEmptySt :: String -> GMInternal
makeEmptySt entry=execState (alloc (Combinator entry) >>= push) $ GMInternal [] M.empty


-- | Interpret a single combinator and returns new combinator to be executed.
aux :: [GMCode] -> GMST IO (Maybe String)
aux (c:cs)=trans (evalGM c) >> aux cs
aux []=do
    node<-trans $ refStack 0 >>= refHeap
    case node of
        App a0 a1 -> trans (push a0) >> aux []
        Combinator x -> return (Just x)
        Struct 0 [f] -> trans pop >> liftIO (liftM ord getChar) >>= \x->aux [MkByte x]
        Struct 1 [x,k] -> trans pop >> trans (refHeap x) >>= liftIO . putChar . f >>
                          trans (push k) >> aux []
        Struct 2 [] -> trans pop >> return Nothing
    where f (Const x)=chr x


-- | Convert 'State' monad to a 'StateT' without chaning its function.
trans :: Monad m => State s a -> StateT s m a
trans (State f)=StateT (\s->return $ f s)


refHeap0 :: Address -> GMS GMNode
refHeap0 addr=liftM ((M.!addr) . heap) get

refHeap :: Address -> GMS GMNode
refHeap addr=do
    n<-refHeap0 addr
    case n of
        Ref addr' -> refHeap addr'
        _ -> return n

refStack :: Int -> GMS Address
refStack n=liftM ((!!n) . stack) get

push :: Address -> GMS ()
push addr=do
    GMInternal st h<-get
    put $ GMInternal (addr:st) h

alloc :: GMNode -> GMS Address
alloc n=do
    GMInternal st h<-get
    let addr=if M.null h then Address 0 else let Address base=fst $ M.findMax h in Address (base+1)
    put $ GMInternal st $ M.insert addr n h
    return addr

pop :: GMS Address
pop=do
    GMInternal (s:ss) h<-get
    put $ GMInternal ss h
    return s

popn :: Int -> GMS [Address]
popn=flip replicateM pop



-- | /Pure/ evaluation
evalGM :: GMCode -> GMS ()
evalGM (Push n)=refStack (n+1) >>= push
evalGM MkApp=do
    [s0,s1]<-popn 2 
    n<-alloc (App s0 s1)
    push n
evalGM (Pack t n)=do
    ss<-popn n
    alloc (Struct t ss) >>= push
evalGM (PushSC n)=do
    alloc (Combinator n) >>= push
evalGM (Slide n)=do
    x<-pop
    popn n
    push x




