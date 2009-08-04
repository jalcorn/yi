{-# LANGUAGE FlexibleInstances, TypeFamilies
  , TemplateHaskell, DeriveDataTypeable #-}
-- Copyright (c) Anders Karlsson 2009
-- Copyright (c) JP Bernardy 2009
-- NOTES:
-- Note if the layout of the first line (not comments)
-- is wrong the parser will only parse what is in the blocks given by Layout.hs
module Yi.Syntax.Haskell ( PModule (..)
                         , PModuleDecl (..)
                         , PImport (..)
                         , Exp (..)
                         , Tree
                         , parse
                         , indentScanner
                         , getExprs
                         ) where

import Prelude ()
import Data.Maybe
import Data.List (filter, union, takeWhile, (\\))
import Yi.IncrementalParse
import Yi.Lexer.Alex
import Yi.Lexer.Haskell
import Yi.Syntax.Layout
import Yi.Syntax.Tree
import qualified Yi.Syntax.BList as BL
import Yi.Syntax
import Yi.Prelude
import Prelude ()
import Data.Monoid
import Data.DeriveTH
import Data.Derive.Foldable
import Data.Maybe
import Data.Tuple (uncurry)
import Control.Arrow ((&&&))

indentScanner :: Scanner (AlexState lexState) (TT)
              -> Scanner (Yi.Syntax.Layout.State Token lexState) (TT)
indentScanner = layoutHandler startsLayout [(Special '(', Special ')'),
                                            (Reserved Let, Reserved In),
                                            (Special '[', Special ']'),
                                            (Special '{', Special '}')]
                         ignoredToken
                         [(Special '<'), (Special '>'), (Special '.')]
                         isBrace

-- HACK: We insert the Special '<', '>', '.',
-- which do not occur in normal haskell
-- parsing.

-- | Check if a token is a brace, this function is used to
-- fix the layout so that do { works correctly
isBrace :: TT -> Bool
isBrace (Tok br _ _) = Special '{' == br

-- | Theese are the tokens ignored by the layout handler.
ignoredToken :: TT -> Bool
ignoredToken (Tok t _ (Posn _ _ _)) = isComment t || t == CppDirective

type Tree = PModule
type PAtom = Exp
type Block = Exp
type PGuard = Exp

-- | A program is some comments followed by a module and a body
data PModule t
    = PModule { comments :: [t]
              , progMod  :: (Maybe (PModule t))
              }
    | ProgMod { modDecl :: (PModuleDecl t)
              , body    :: (PModule t)  -- ^ The module declaration part
              }
    | Body { imports :: [PImport t]
           , content :: (Block t)
           , extraContent :: (Block t) -- ^ The body of the module
           }
  deriving Show

-- | A module
data PModuleDecl t = PModuleDecl { moduleKeyword :: (PAtom t)
                                 , name          :: (PAtom t)
                                 , exports       :: (Exp t)
                                 , whereKeyword  :: (Exp t)
                                 }
    deriving Show

-- | Imported things
data PImport t = PImport { importKeyword :: (PAtom t)
                         , qual          :: (Exp t)
                         , name'         :: (PAtom t)
                         , as            :: (Exp t)
                         , specification :: (Exp t)
                         }
    deriving Show

-- | Exp can be expression or declaration
data Exp t
      -- Top declarations
    = TS t [Exp t] -- ^ Type signature 
    | PType { typeKeyword :: (PAtom t)
            , typeCons    :: (Exp t)
            , equal       :: (PAtom t)
            , btype       :: (Exp t)
            } -- ^ Type declaration
    | PData { dataKeyword :: (PAtom t)
            , dtypeCons   :: (Exp t)
            , dEqual      :: (Exp t)
            , dataRhs     :: (Exp t)
            }  -- ^ Data declaration
    | PData' { dEqual    :: (PAtom t)
             , dataCons  :: (Exp t) -- ^ Data declaration RHS
             }
    | PClass { cKeyword :: (PAtom t) -- Can be class or instance
             , cHead        :: (Exp t)
             , cwhere       :: (Exp t) -- ^ Class declaration
             }
      -- declaration
      -- declarations and parts of them follow
    | Paren (PAtom t) [Exp t] (PAtom t) -- ^ A parenthesized, bracked or braced
    | Block (BL.BList [Exp t]) -- ^ A block of things separated by layout
    | PAtom t [t] -- ^ An atom is a token followed by many comments
    | Expr [Exp t] -- ^
    | PWhere (PAtom t) (Exp t) -- ^ Where clause
    | Bin (Exp t) (Exp t)
       -- an error with comments following so we never color comments in wrong
       -- color. The error has an extra token, the Special '!' token to
       -- indicate that it contains an error
    | PError { errorTok    :: t
             , marker      :: t
             , commentList :: [t] -- ^ An wrapper for errors
             }
      -- rhs that begins with Equal
    | RHS (PAtom t) [Exp t] -- ^ Righthandside of functions with =
    | Opt (Maybe (Exp t)) -- ^ An optional
    | Modid t [t] -- ^ Module identifier
    | Context (Exp t) (Exp t) (PAtom t) -- ^
    | PGuard [PGuard t] -- ^ Righthandside of functions with |
      -- the PAtom in PGuard' does not contain any comments
    | PGuard' (PAtom t) [Exp t] (PAtom t)
      -- type constructor is just a wrapper to indicate which highlightning to
      -- use.
    | TC (Exp t) -- ^ Type constructor
      -- data constructor same as with the TC constructor
    | DC (Exp t) -- ^ Data constructor
    | PLet (PAtom t) (Exp t) (Exp t) -- ^ let expression
    | PIn t [Exp t]
  deriving Show

instance SubTree (Exp TT) where
    type Element (Exp TT) = TT
    foldMapToksAfter begin f t0 = work t0
        where work (Paren e e' e'') = work e <> foldMap work e' <> work e''
              work (Expr e)     = foldMap work e
              work (PWhere e' e) = work e' <> work e
              work (Bin e e')   = work e <> work e'
              work (RHS e l)    = work e <> foldMap work l
              work (Opt (Just t)) = work t
              work (Opt Nothing)  = mempty
              work (Modid t l)    = f t
                                 <> fold' l
              work (Context e e' t) = work e
                                   <> work e'
                                   <> work t
              work (PType kw e e' exp) = work kw
                                             <> work e
                                             <> work e'
                                             <> work exp
              work (PData kw e e' e'') = work kw
                                       <> work e
                                       <> work e'
                                       <> work e''
              work (PData' eq e) = work eq
                                    <> work e
              work (PGuard l) = foldMap work l
              work (PGuard' t e t') = work t
                                      <> foldMap work e
                                      <> work t'
              work (PAtom t c)  = f t <> fold' c
              work (PError t' t c) = f t' <> f t <> fold' c
              work (TS t e) = f t <> foldMap work e
              work (DC e) = work e
              work (TC e) = work e
              work (PLet t e e') = work t
                                <> work e
                                <> work e'
              work (PIn t l) = f t <> foldMap work l
              work (Block s) = BL.foldMapAfter
                                begin (foldMapToksAfter begin f) s
              work (PClass e e' e'') = work e <> work e' <> work e''
              fold' = foldMapToksAfter begin f
    foldMapToks = foldMap . foldMapToks

instance SubTree (PModule TT) where
    type Element (PModule TT) = TT
    foldMapToksAfter begin f t0 = work t0
        where work (PModule m (Just p)) = foldMapToksAfter begin f m <> work p
              work (PModule m Nothing) = foldMapToksAfter begin f m
              work (ProgMod _ p) = work p
              work (Body _ (Block t) (Block t')) = BL.foldMapAfter
                                begin (foldMapToksAfter begin f) t
                                       <> BL.foldMapAfter
                                       begin (foldMapToksAfter begin f) t'
              work _ = undefined
    foldMapToks = foldMap . foldMapToks

instance SubTree (PImport TT) where
    type Element (PImport TT) = TT
    foldMapToksAfter begin f t0 = work t0
        where work (PImport at e at' e' e'') = fold' at
                                            <> fold' e
                                            <> fold' at'
                                            <> fold' e'
                                            <> fold' e''
              fold' = foldMapToksAfter begin f
    foldMapToks = foldMap . foldMapToks

$(derive makeFoldable ''PImport)
$(derive makeFoldable ''PModuleDecl)
$(derive makeFoldable ''PModule)

$(derive makeFoldable ''Exp)
instance IsTree Exp where
   subtrees tree = case tree of
       (Paren l g r)  -> l:g ++ [r]
       (RHS l g)      -> l:g
       (Block s)      -> concat s
       (PLet l s i)   -> l:s:[i]
       (PIn _ ts)     -> ts
       (Expr a)       -> a
       (PClass a b c) -> [a,b,c]
       (PWhere a b) -> [a,b]
       (Opt (Just x)) -> [x]
       (Bin a b) -> [a,b]
       (PType a b c d) -> [a,b,c,d]
       (PData a b c d) -> [a,b,c,d]
       (PData' a b) -> [a,b] 
       (Context a b c) -> [a,b,c]
       (PGuard xs) -> xs
       (PGuard' a b c) -> a:b ++ [c]
       (TC e) -> [e]
       (DC e) -> [e]
       _              -> []

getExprs :: PModule TT -> [Exp TT]
getExprs (ProgMod _ b)     = getExprs b
getExprs (Body _ exp exp') = [exp, exp']
getExprs (PModule _ (Just e)) = getExprs e
getExprs _                 = [] -- error "no match"

-- | The parser
parse :: P TT (Tree TT)
parse = pModule <* eof

-- | @pModule@ parse a module
pModule :: Parser TT (PModule TT)
pModule = PModule <$> pComments <*> optional
           (pBlockOf' (ProgMod <$> pModuleDecl
                       <*> pModBody <|> pBody))

-- | Parse a body that follows a module
pModBody :: Parser TT (PModule TT)
pModBody = (exact [startBlock] *>
            (Body <$> pImports
             <*> ((pTestTok elems *> pBod)
                  <|> pEmptyBL) <* exact [endBlock]
             <*> pBod
            <|> Body <$> noImports
             <*> ((pBod <|> pEmptyBL) <* exact [endBlock])
             <*> pBod))
       <|> (exact [nextLine] *> pBody)
       <|> Body <$> pEmpty <*> pEmptyBL <*> pEmptyBL
    where pBod  = Block <$> pBlocks pTopDecl
          elems = [(Special ';'), nextLine, startBlock]

-- | @pEmptyBL@ A parser returning an empty block
pEmptyBL :: Parser TT (Exp TT)
pEmptyBL = Block <$> pure BL.nil

-- | Parse a body of a program
pBody :: Parser TT (PModule TT)
pBody = Body <$> noImports <*> (Block <$> pBlocks pTopDecl) <*> pEmptyBL
    <|> Body <$> pImports <*> ((pTestTok elems *> (Block <$> pBlocks pTopDecl))
                               <|> pEmptyBL) <*> pEmptyBL
    where elems = [nextLine, startBlock]

noImports :: Parser TT [a]
noImports = notNext [Reserved Import] *> pEmpty
    where notNext f = testNext $ uncurry (||) . (&&&) isNothing
                      (flip notElem f . tokT . fromJust)

-- Helper functions for parsing follows
-- | Parse Variables
pVarId :: Parser TT (Exp TT)
pVarId = pAtom [VarIdent, (Reserved Other), (Reserved As)]

-- | Parse VarIdent and ConsIdent
pQvarid :: Parser TT (Exp TT)
pQvarid = pAtom [VarIdent, ConsIdent, (Reserved Other), (Reserved As)]

-- | Parse an operator using please
pQvarsym :: Parser TT (Exp TT)
pQvarsym = pParen ((:) <$> please (PAtom <$> sym isOperator <*> pComments)
                   <*> pEmpty)

-- | Parse any operator
isOperator :: Token -> Bool
isOperator (Operator _)     = True
isOperator (ReservedOp _)   = True
isOperator (ConsOperator _) = True
isOperator _                = False

-- | Parse a consident
pQtycon :: Parser TT (Exp TT)
pQtycon = pAtom [ConsIdent]

-- | Parse many variables
pVars :: Parser TT (Exp TT)
pVars = pMany pVarId

-- | Parse a nextline token (the nexLine token is inserted by Layout.hs)
nextLine :: Token
nextLine = Special '.'

-- | Parse a startBlock token
startBlock :: Token
startBlock = Special '<'

-- | Parse a endBlock token
endBlock :: Token
endBlock = Special '>'

pEmpty :: Applicative f =>  f [a]
pEmpty = pure []

pToList :: Applicative f =>  f a -> f [a]
pToList = (box <$>)
    where box x = [x]

-- | @sym f@ returns a parser parsing @f@ as a special symbol
sym :: (Token -> Bool) -> Parser TT TT
sym f = symbol (f . tokT)

-- | @exact tokList@ parse anything that is in @tokList@
exact :: [Token] -> Parser TT TT
exact = sym . flip elem

-- | Create a special character symbol
newT :: Char -> TT
newT = tokFromT . Special

-- | @please p@ returns a parser parsing either @p@ or recovers with the
-- (Special '!') token.
please :: Parser TT (Exp TT) -> Parser TT (Exp TT)
please = (<|>) (PError <$> recoverWith (pure $ newT '!')
                <*> pure (newT '!')
                <*> pEmpty)

-- | Parse anything that is an error
pErr :: Parser TT (Exp TT)
pErr = PError <$> recoverWith (sym $ not . uncurry (||) . (&&&) isComment
                               (== CppDirective))
   <*> pure (newT '!')
   <*> pComments

-- | Parse an ConsIdent
ppCons :: Parser TT (Exp TT)
ppCons = ppAtom [ConsIdent]

-- | Parse a keyword
pKW :: [Token] -> Parser TT (Exp TT) -> Parser TT (Exp TT)
pKW k r = Bin <$> pAtom k <*> r

-- | Parse an unary operator with and without using please
pOP, ppOP :: [Token] -> Parser TT (Exp TT) -> Parser TT (Exp TT)
pOP op r = Bin <$> pAtom op <*> r

ppOP op r = Bin <$> ppAtom op <*> r

-- | Parse comments
pComments :: Parser TT [TT]
pComments = many $ sym $ uncurry (||) . (&&&) isComment (== CppDirective)

-- | Parse something thats optional
pOpt :: Parser TT (Exp TT) -> Parser TT (Exp TT)
pOpt x = Opt <$> optional x

-- | Parse an atom with, and without using please
pAtom, ppAtom :: [Token] -> Parser TT (Exp TT)
pAtom = flip pCAtom pComments

ppAtom at =  pAtom at <|> recoverAtom

recoverAtom :: Parser TT (Exp TT)
recoverAtom = PAtom <$> recoverWith (pure $ newT '!') <*> pEmpty

-- | Parse an atom with optional comments
pCAtom :: [Token] -> Parser TT [TT] -> Parser TT (Exp TT)
pCAtom r c = PAtom <$> exact r <*> c

pBareAtom a = pCAtom a pEmpty

-- | @pSepBy p sep@ parse /zero/ or more occurences of @p@, separated
-- by @sep@, with optional ending @sep@,
-- this is quite similar to the sepBy function provided in
-- Parsec, but this one allows an optional extra separator at the end.
--
-- > commaSep p = p `pSepBy` (symbol (==(Special ',')))

pSepBy :: Parser TT (Exp TT) -> Parser TT (Exp TT) -> Parser TT [Exp TT]
pSepBy p sep = pEmpty
           <|> (:) <$> p <*> (pSepBy1 p sep <|> pEmpty)
           <|> pToList sep -- optional ending separator
    where pSepBy1 r p' = (:) <$> p' <*> (pEmpty <|> pSepBy1 p' r)

-- | Separate a list of things separated with comma inside of parenthesis
pParenSep :: Parser TT (Exp TT) -> Parser TT (Exp TT)
pParenSep = pParen . flip pSepBy pComma

-- | Parse a comma separator
pComma :: Parser TT (Exp TT)
pComma = pAtom [Special ',']

-- End of helper functions Parsing different parts follows

-- | Parse a Module declaration
pModuleDecl :: Parser TT (PModuleDecl TT)
pModuleDecl = PModuleDecl <$> pAtom [Reserved Module]
          <*> ppAtom [ConsIdent]
          <*> pOpt (pParenSep pExport)
          <*> (optional (exact [nextLine]) *>
               (Bin <$> ppAtom [Reserved Where])
               <*> pMany pErr') <* pTestTok elems
    where elems = [nextLine, startBlock, endBlock]
          pErr' = PError <$>
                  recoverWith (sym $ not . uncurry (||) . (&&&) isComment
                               (flip elem [CppDirective
                                          , startBlock
                                          , endBlock
                                          , nextLine]))
              <*> pure (newT '!')
              <*> pComments

pExport :: Parser TT (Exp TT)
pExport = optional (exact [nextLine]) *> please
        ( pVarId
          <|> pEModule
          <|> Bin <$> pQvarsym <*> (DC <$> pOpt expSpec) -- typeOperator
          <|> Bin <$> (TC <$> pQtycon) <*> (DC <$> pOpt expSpec)
        )
        where expSpec = pParen (pToList (please (pAtom [ReservedOp DoubleDot]))
                                <|> pSepBy pQvarid pComma)

-- | Check if next token is in given list
pTestTok :: [Token] -> Parser TT ()
pTestTok f = testNext (uncurry (||) . (&&&) isNothing
                       (flip elem f . tokT . fromJust))

-- | Parse several imports
pImports :: Parser TT [PImport TT]
pImports = many (pImport
                 <* pTestTok pEol
                 <* optional (some $ exact [nextLine, Special ';']))
        where pEol = [(Special ';'), nextLine, endBlock]
 
-- | Parse one import
pImport :: Parser TT (PImport TT)
pImport = PImport  <$> pAtom [Reserved Import]
      <*> pOpt (pAtom [Reserved Qualified])
      <*> ppAtom [ConsIdent]
      <*> pOpt (pKW [Reserved As] ppCons)
      <*> (TC <$> pImpSpec)
        where pImpSpec = Bin <$> pKW [Reserved Hiding]
                                  (please pImpS) <*> pMany pErr
                     <|> Bin <$> pImpS <*> pMany pErr
                     <|> pMany pErr
              pImpS    = DC <$> pParenSep pExp'
              pExp'    = Bin
                     <$> (PAtom <$> sym
                          (uncurry (||) . (&&&)
                           (flip elem [VarIdent, ConsIdent])
                           isOperator) <*> pComments
                          <|>  pQvarsym)
                     <*> pOpt pImpS

-- | Parse simple type synonyms
pType :: Parser TT (Exp TT)
pType = PType <$> pAtom [Reserved Type]
     <*> (TC . Expr <$> pTypeExpr')
     <*> ppAtom [ReservedOp Equal]
     <*> (TC . Expr <$> pTypeExpr')


-- | Parse data declarations
pData :: Parser TT (Exp TT)
pData = PData <$> pAtom [Reserved Data]
     <*> (TC . Expr <$> pTypeExpr')
     <*> pOpt (pDataRHS <|> pGadt)
     <*> pOpt pDeriving


pGadt = pWhere pTypeDecl

-- | Parse second half of the data declaration, if there is one
pDataRHS :: Parser TT (Exp TT)
pDataRHS = PData' <$> pAtom [ReservedOp Equal]  <*> pConstrs


-- | Parse a deriving
pDeriving :: Parser TT (Exp TT)
pDeriving = pKW [Reserved Deriving] (TC . Expr <$> pTypeExpr')

pAtype :: Parser TT (Exp TT)
pAtype = pAtype'
     <|> pErr'
    where pErr' = PError
              <$> recoverWith (sym $ not .
                               uncurry (||) . (&&&) isComment
                               (flip elem [ CppDirective
                                          , (Special '(')
                                          , (Special '[')
                                          , VarIdent
                                          , ConsIdent
                                          , (Reserved Other)
                                          , (Reserved As)])
                               )
              <*> pure (newT '!')
              <*> pComments

pAtype' :: Parser TT (Exp TT)
pAtype' = pQvarid
      <|> pParen (many $ pExprElem [])
      <|> pBrack (many $ pExprElem [])

pContext :: Parser TT (Exp TT)
pContext = Context <$> pOpt pForAll
       <*> (TC <$> (pClass' <|> pParenSep pClass'))
       <*> ppAtom [ReservedOp DoubleRightArrow]
        where pClass' :: Parser TT (Exp TT)
              pClass' = Bin <$> pQtycon
                   <*> (please pVarId
                        <|> pParen ((:) <$> please pVarId
                                    <*> many pAtype'))

-- | Parse for all
pForAll :: Parser TT (Exp TT)
pForAll = pKW [Reserved Forall]
          (Bin <$> pVars <*> ppAtom [Operator "."])

pConstrs :: Parser TT (Exp TT)
pConstrs = Bin <$> (Bin <$> pOpt pContext <*> pConstr)
       <*> pMany (pOP [ReservedOp Pipe]
                  (Bin <$> pOpt pContext <*> please pConstr))

pConstr :: Parser TT (Exp TT)
pConstr = Bin <$> pOpt pForAll
      <*> (Bin <$>
           (Bin <$> (DC <$> pAtype) <*>
            (TC <$> pMany (strictF pAtype))) <*> pOpt st)
      <|> Bin <$> lrHs <*> pMany (strictF pAtype)
      <|> pErr
    where lrHs = pOP [Operator "!"] pAtype
          st = pCBrace ((Expr <$> pTypeDecl) `sepBy1` pBareAtom [Special ',']) pEmpty
          -- named fields declarations

-- | Parse optional strict variables
strictF :: Parser TT (Exp TT) -> Parser TT (Exp TT)
strictF a = Bin <$> pOpt (pAtom [Operator "!"]) <*> a


-- | Exporting module
pEModule ::Parser TT (Exp TT)
pEModule = pKW [Reserved Module]
         $ please (Modid <$> exact [ConsIdent] <*> pComments)

-- | Parse a Let expression
pLet :: Parser TT (Exp TT)
pLet = PLet <$> pAtom [Reserved Let]
   <*> pBlock pFunDecl
   <*> pOpt (pBareAtom [Reserved In])

-- | Parse a Do block
pDo :: Parser TT (Exp TT)
pDo = Bin <$> pAtom [Reserved Do]
          <*> pBlock (pExpr ((Special ';' : recognizedSometimes) \\ [ReservedOp LeftArrow]))

-- | Parse part of a lambda binding.
pLambda = Bin <$> pAtom [ReservedOp BackSlash] <*> (Bin <$> (Expr <$> pPattern) <*> please (pBareAtom [ReservedOp RightArrow]))

-- | Parse an Of block
pOf :: Parser TT (Exp TT)
pOf = Bin <$> pAtom [Reserved Of]
          <*> pBlock (pToList pAlternative)

pAlternative = Bin <$> (Expr <$> pPattern)
                   <*> please (pFunRHS (ReservedOp RightArrow))

-- | Parse classes and instances
-- This is very imprecise, but shall suffice for now.
-- At least is does not complain too often.
pClass :: Parser TT (Exp TT)
pClass = PClass <$> pAtom [Reserved Class, Reserved Instance]
                <*> (TC . Expr <$>  pTypeExpr')
                <*> please (pWhere pTopDecl)
                -- use topDecl since we have associated types and such.
                      

-- | Parse some guards and a where clause
pGuard :: Token -> Parser TT (Exp TT)
pGuard equalSign = PGuard
     <$> some (PGuard' <$> pCAtom [ReservedOp Pipe] pEmpty <*>
               -- comments are by default parsed after this
               pExpr (recognizedSometimes \\ [ReservedOp LeftArrow, Special ',']) -- those two symbols can appear in guards.
               <*> please (pEq equalSign))
               -- this must be -> if used in case

-- | Right-hand-side of a function or case equation (after the pattern)
pFunRHS :: Token -> Parser TT (Exp TT)
pFunRHS equalSign = Bin <$> (pGuard equalSign <|> pEq equalSign) <*> pOpt (pWhere pFunDecl)

pWhere p = PWhere <$> pAtom [Reserved Where] <*> please (pBlock p)

-- Note that this can both parse an equation and a type declaration.
-- Since they can start with the same token, the left part is factored here.
pDecl :: Bool -> Bool -> Parser TT [Exp TT]
pDecl acceptType acceptEqu = (Yuck $ Enter "missing end of type or equation declaration" $ pure [])
             <|> ((:) <$> pElem False recognizedSometimes <*> pDecl acceptType acceptEqu)
             <|> ((:) <$> pBareAtom [Special ','] <*> pDecl acceptType False)
                 -- if a comma is found, then the rest must be a type declaration.
             <|> (if acceptType then pTypeEnding else empty)
             <|> (if acceptEqu  then pEquEnding else empty)
    where pTypeEnding = ((:) <$> (TS <$> exact [ReservedOp DoubleColon] <*> pTypeExpr') <*> pure [])
          pEquEnding = ((:) <$> pFunRHS (ReservedOp Equal) <*> pure [])

pFunDecl = pDecl True True
pTypeDecl = pDecl True False
pEquation = pDecl False True


-- | The RHS of an equation.
pEq :: Token -> Parser TT (Exp TT)
pEq equalSign = RHS <$> pBareAtom [equalSign] <*> pExpr'

-- | Parse many of something
pMany :: Parser TT (Exp TT) -> Parser TT (Exp TT)
pMany p = Expr <$> many p

-- | Parse a some of something separated by the token (Special '.')
pBlocks :: Parser TT r -> Parser TT (BL.BList r)
pBlocks p =  p `BL.sepBy1` exact [nextLine]

-- | Parse a some of something separated by the token (Special '.'), or nothing
pBlocks' :: Parser TT r -> Parser TT (BL.BList r)
pBlocks' p =  pBlocks p <|> pure BL.nil

-- | Parse a block of some something separated by the tok (Special '.')
pBlockOf :: Parser TT [(Exp TT)] -> Parser TT (Exp TT)
pBlockOf p  = Block <$> pBlockOf' (pBlocks p) -- see HACK above


pBlock :: Parser TT [Exp TT] -> Parser TT (Exp TT)
pBlock p = pBlockOf' (Block <$> pBlocks' p) 
       <|> pBrace (concat <$> (p `sepBy1` exact [Special ';']) <|> pure [])
       <|> (Yuck $ Enter "block expected" $ pEmptyBL)

-- | Parse something surrounded by (Special '<') and (Special '>')
pBlockOf' :: Parser TT a -> Parser TT a
pBlockOf' p = exact [startBlock] *> p <* exact [endBlock] -- see HACK above
-- note that, by construction, '<' and '>' will always be matched, so
-- we don't try to recover errors with them.

-- | Parse something that can contain a data, type declaration or a class
pTopDecl :: Parser TT [(Exp TT)]
pTopDecl = pFunDecl 
          <|> pToList pType
          <|> pToList pData
          <|> pToList pClass
          <|> pEmpty


-- | A "normal" expression, where none of the following symbols are acceptable.
pExpr' = pExpr recognizedSometimes

recognizedSometimes = [ReservedOp DoubleDot, 
                       Special ',', 
                       ReservedOp Pipe,
                       ReservedOp Equal,
                       ReservedOp LeftArrow,
                       ReservedOp RightArrow,
                       ReservedOp DoubleRightArrow,
                       ReservedOp BackSlash,
                       ReservedOp DoubleColon
                      ]

-- | Parse an expression, as a concatenation of elements.
pExpr :: [Token] -> Parser TT [Exp TT]
pExpr = pExprOrPattern True

-- | Parse an expression, as a concatenation of elements.
pExprOrPattern :: Bool -> [Token] -> Parser TT [Exp TT]
pExprOrPattern isExpresssion at = pure [] 
       <|> ((:) <$> pElem isExpresssion at          <*> pExpr at)
       <|> ((:) <$> (TS <$> exact [ReservedOp DoubleColon] <*> pTypeExpr') <*> pure [])
     -- TODO: not really correct: in (x :: X , y :: Z), all after the first :: will be a "type".

pPattern = pExprOrPattern False recognizedSometimes

pExprElem = pElem True

-- | Parse an "element" of an expression or a pattern.
-- "at" is a list of symbols that, if found, should be considered errors.
pElem :: Bool -> [Token] -> Parser TT (Exp TT)
pElem isExpresssion at
    = pCParen (pExprOrPattern isExpresssion (recognizedSometimes \\ [Special ','])) pEmpty -- might be a tuple, so accept commas as noise
  <|> pCBrack (pExprOrPattern isExpresssion (recognizedSometimes \\ [ReservedOp DoubleDot, ReservedOp Pipe, ReservedOp LeftArrow, Special ','])) pEmpty -- list thing
  <|> pCBrace (many $ pElem isExpresssion (recognizedSometimes \\ [ReservedOp Equal, Special ',', ReservedOp Pipe])) pEmpty -- record: TODO: improve
  <|> (Yuck $ Enter "incorrectly placed block" $ pBlockOf (pExpr recognizedSometimes)) -- no error token, but the previous keyword will be one. (of, where, ...)
  <|> (PError <$> recoverWith
       (sym $ flip elem $ isNoiseErr at) <*> pure (newT '!') <*> pEmpty)
  <|> (PAtom <$> sym (flip notElem (isNotNoise at)) <*> pEmpty)
  <|> if isExpresssion then (pLet <|> pDo <|> pOf <|> pLambda) else empty
  -- TODO: support type expressions

pTypeExpr at = many (pTypeElem at)
pTypeExpr' = pTypeExpr (recognizedSometimes \\ [ReservedOp RightArrow, 
                                                ReservedOp DoubleRightArrow])

pTypeElem :: [Token] -> Parser TT (Exp TT)
pTypeElem at 
    = pCParen (pTypeExpr (recognizedSometimes \\ [ReservedOp RightArrow,
                                                  ReservedOp DoubleRightArrow,
                                                  Special ','])) pEmpty -- might be a tuple, so accept commas as noise
  <|> pCBrack pTypeExpr' pEmpty
  <|> pCBrace pTypeExpr' pEmpty -- TODO: this is an error: mark as such.
  <|> (Yuck $ Enter "incorrectly placed block" $ pBlockOf (pExpr recognizedSometimes))
  <|> (PError <$> recoverWith
       (sym $ flip elem $ isNoiseErr at) <*> pure (newT '!') <*> pEmpty)
  <|> (PAtom <$> sym (flip notElem (isNotNoise at)) <*> pEmpty)

-- | List of things that allways should be parsed as errors
isNoiseErr :: [Token] -> [Token]
isNoiseErr r = recoverableSymbols ++ r

recoverableSymbols = recognizedSymbols \\ fmap Special "([{<>."
-- We just don't recover opening symbols (only closing are "fixed").
-- Layout symbols "<>." are never recovered, because layout is constructed correctly.

-- | List of things that should not be parsed as noise
isNotNoise :: [Token] -> [Token]
isNotNoise r = recognizedSymbols ++ r

-- | These symbols are always properly recognized, and therefore they
-- should never be accepted as "noise" inside expressions.
recognizedSymbols = 
    [ (Reserved Let)
    , (Reserved In)
    , (Reserved Do)
    , (Reserved Of)
    , (Reserved Class)
    , (Reserved Instance)
    , (Reserved Deriving)
    , (Reserved Module)
    , (Reserved Import)
    , (Reserved Type)
    , (Reserved Data)
    , (Reserved Where)] ++ fmap Special "()[]{}<>."

-- | Parse parenthesis, brackets and braces containing
-- an expression followed by possible comments
pCParen, pCBrace, pCBrack
       :: Parser TT [Exp TT] -> Parser TT [TT] -> Parser TT (Exp TT)

pCParen p c = Paren <$> pCAtom [Special '('] c
          <*> p <*> (recoverAtom <|> pCAtom [Special ')'] c)

pCBrace p c = Paren  <$> pCAtom [Special '{'] c
          <*> p <*> (recoverAtom <|> pCAtom [Special '}'] c)

pCBrack p c = Paren  <$>  pCAtom [Special '['] c
          <*> p <*> (recoverAtom <|> pCAtom [Special ']'] c)

pParen, pBrace, pBrack :: Parser TT [Exp TT] -> Parser TT (Exp TT)

pParen = flip pCParen pComments

pBrace = flip pCBrace pComments

pBrack = flip pCBrack pComments