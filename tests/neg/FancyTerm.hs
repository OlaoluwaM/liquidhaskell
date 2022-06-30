{-# LANGUAGE GADTs #-}
data Tree a where 
    Leaf :: a -> Tree a 
    Node :: (Int -> (Tree a)) -> Tree a 


{-@ measure $$self :: a  @-}

{-@ measure tsize :: Tree a -> Nat @-}
{-@ data Tree a where 
      Leaf :: a -> {t:Tree a  | tsize t == 0 } 
      Node :: f:(Int -> ({tt:Tree a | tsize tt < tsize $$self && 0 <= tsize tt })) 
           -> {t:Tree a | 0 <= tsize t}  @-}

{-@ ignore node @-}
{-@ node :: (Int -> {tin:Tree a |  0 <= tsize tin}) -> {t:Tree a | 0 <= tsize t} @-}
node :: (Int -> Tree a) -> Tree a 
node = Node 

{-@ mapTr :: (a -> a) -> t:Tree a -> {o:Tree a | true} / [tsize t] @-}
mapTr :: (a -> a) -> Tree a -> Tree a 
mapTr f (Leaf x) = Leaf $ f x 
mapTr f (Node n) = mapTr f (Node n) 
