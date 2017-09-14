{-# LANGUAGE DataKinds, GADTs, RankNTypes, ScopedTypeVariables, TypeOperators #-}
module Interpreter
( diffTerms
, decoratingWith
, diffTermsWith
, comparableByConstructor
) where

import Algorithm
import Control.Monad.Free.Freer
import Data.Align.Generic
import Data.Functor.Classes (Eq1)
import Data.Hashable (Hashable)
import Data.Maybe (isJust)
import Data.Record
import Data.Text (Text)
import Diff
import Info hiding (Return)
import RWS
import Syntax as S hiding (Return)
import Term


-- | Diff two terms recursively, given functions characterizing the diffing.
diffTerms :: HasField fields Category
          => Term Syntax (Record fields) -- ^ A term representing the old state.
          -> Term Syntax (Record fields) -- ^ A term representing the new state.
          -> Diff Syntax (Record fields) (Record fields)
diffTerms = decoratingWith getLabel (diffTermsWith algorithmWithTerms comparableByCategory)

-- | Diff two terms by decorating with feature vectors computed using the supplied labelling algebra, and stripping the feature vectors from the resulting diff.
decoratingWith :: (Hashable label, Traversable f)
               => (forall a. TermF f (Record fields) a -> label)
               -> (Term f (Record (FeatureVector ': fields)) -> Term f (Record (FeatureVector ': fields)) -> Diff f (Record (FeatureVector ': fields)) (Record (FeatureVector ': fields)))
               -> Term f (Record fields)
               -> Term f (Record fields)
               -> Diff f (Record fields) (Record fields)
decoratingWith getLabel differ t1 t2 = stripDiff (differ (defaultFeatureVectorDecorator getLabel t1) (defaultFeatureVectorDecorator getLabel t2))

-- | Diff a pair of terms recurisvely, using the supplied continuation and 'ComparabilityRelation'.
diffTermsWith :: forall f fields . (Traversable f, GAlign f, Eq1 f, HasField fields FeatureVector)
              => (Term f (Record fields) -> Term f (Record fields) -> Algorithm (Term f) (Diff f) (Record fields) (Record fields) (Diff f (Record fields) (Record fields))) -- ^ A function producing syntax-directed continuations of the algorithm.
              -> ComparabilityRelation f (Record fields) (Record fields) -- ^ A relation on terms used to determine comparability and equality.
              -> Term f (Record fields) -- ^ A term representing the old state.
              -> Term f (Record fields) -- ^ A term representing the new state.
              -> Diff f (Record fields) (Record fields) -- ^ The resulting diff.
diffTermsWith refine comparable t1 t2 = runFreer decompose (diff t1 t2)
  where decompose :: AlgorithmF (Term f) (Diff f) (Record fields) (Record fields) result -> Algorithm (Term f) (Diff f) (Record fields) (Record fields) result
        decompose step = case step of
          Algorithm.Diff t1 t2 -> refine t1 t2
          Linear t1 t2 -> case galignWith diffThese (unwrap t1) (unwrap t2) of
            Just result -> merge (extract t1, extract t2) <$> sequenceA result
            _ -> byReplacing t1 t2
          RWS as bs -> traverse diffThese (rws comparable as bs)
          Delete a -> pure (deleting a)
          Insert b -> pure (inserting b)
          Replace a b -> pure (replacing a b)

-- | Compute the label for a given term, suitable for inclusion in a _p_,_q_-gram.
getLabel :: HasField fields Category => TermF Syntax (Record fields) a -> (Category, Maybe Text)
getLabel (In h t) = (Info.category h, case t of
  Leaf s -> Just s
  _ -> Nothing)


-- | Construct an algorithm to diff a pair of terms.
algorithmWithTerms :: Term Syntax (Record fields)
                   -> Term Syntax (Record fields)
                   -> Algorithm (Term Syntax) (Diff Syntax) (Record fields) (Record fields) (Diff Syntax (Record fields) (Record fields))
algorithmWithTerms t1 t2 = case (unwrap t1, unwrap t2) of
  (Indexed a, Indexed b) ->
    annotate . Indexed <$> byRWS a b
  (S.Module idA a, S.Module idB b) ->
    (annotate .) . S.Module <$> linearly idA idB <*> byRWS a b
  (S.FunctionCall identifierA typeParamsA argsA, S.FunctionCall identifierB typeParamsB argsB) -> fmap annotate $
    S.FunctionCall <$> linearly identifierA identifierB
                   <*> byRWS typeParamsA typeParamsB
                   <*> byRWS argsA argsB
  (S.Switch exprA casesA, S.Switch exprB casesB) -> fmap annotate $
    S.Switch <$> byRWS exprA exprB
             <*> byRWS casesA casesB
  (S.Object tyA a, S.Object tyB b) -> fmap annotate $
    S.Object <$> diffMaybe tyA tyB
             <*> byRWS a b
  (Commented commentsA a, Commented commentsB b) -> fmap annotate $
    Commented <$> byRWS commentsA commentsB
              <*> diffMaybe a b
  (Array tyA a, Array tyB b) -> fmap annotate $
    Array <$> diffMaybe tyA tyB
          <*> byRWS a b
  (S.Class identifierA clausesA expressionsA, S.Class identifierB clausesB expressionsB) -> fmap annotate $
    S.Class <$> linearly identifierA identifierB
            <*> byRWS clausesA clausesB
            <*> byRWS expressionsA expressionsB
  (S.Method clausesA identifierA receiverA paramsA expressionsA, S.Method clausesB identifierB receiverB paramsB expressionsB) -> fmap annotate $
    S.Method <$> byRWS clausesA clausesB
             <*> linearly identifierA identifierB
             <*> diffMaybe receiverA receiverB
             <*> byRWS paramsA paramsB
             <*> byRWS expressionsA expressionsB
  (S.Function idA paramsA bodyA, S.Function idB paramsB bodyB) -> fmap annotate $
    S.Function <$> linearly idA idB
               <*> byRWS paramsA paramsB
               <*> byRWS bodyA bodyB
  _ -> linearly t1 t2
  where
    annotate = merge (extract t1, extract t2)


-- | Test whether two terms are comparable by their Category.
comparableByCategory :: HasField fields Category => ComparabilityRelation syntax (Record fields) (Record fields)
comparableByCategory (In a _) (In b _) = category a == category b

-- | Test whether two terms are comparable by their constructor.
comparableByConstructor :: GAlign syntax => ComparabilityRelation syntax (Record fields) (Record fields)
comparableByConstructor (In _ a) (In _ b) = isJust (galign a b)
