{-# LANGUAGE OverloadedStrings, LambdaCase #-}
module Poseidon.GenotypeData where

import           Poseidon.Utils             (PoseidonException (..))

import           Control.Monad              (forM, forM_, when, void)
import           Control.Monad.Catch        (throwM, MonadThrow)
import           Control.Monad.IO.Class     (liftIO)
import           Data.Aeson                 (FromJSON, ToJSON, object,
                                             parseJSON, toJSON, withObject,
                                             withText, (.:), (.=))
import           Data.ByteString            (isPrefixOf)
import           Data.List                  (nub, sort)
import qualified Data.Text                  as T
import qualified Data.Vector                as V
import           Pipes                      (Producer, (>->))
import           Pipes.OrderedZip           (orderCheckPipe, orderedZip)
import qualified Pipes.Prelude              as P
import           Pipes.Safe                 (MonadSafe)
import           SequenceFormats.Eigenstrat (EigenstratIndEntry (..),
                                             EigenstratSnpEntry (..),
                                             GenoEntry (..), GenoLine,
                                             readEigenstrat, readEigenstratInd)
import           SequenceFormats.Plink      (readFamFile, readPlink)
import           System.Directory           (doesFileExist)
import           System.IO                  (hPutStrLn, stderr)

-- | A datatype to specify genotype files
data GenotypeDataSpec = GenotypeDataSpec
    { format   :: GenotypeFormatSpec
    -- ^ the genotype format
    , genoFile :: FilePath
    -- ^ path to the geno file
    , snpFile  :: FilePath
    -- ^ path to the snp file
    , indFile  :: FilePath
    -- ^ path to the ind file
    }
    deriving (Show, Eq)

-- | To facilitate automatic parsing of GenotypeDataSpec from JSON files
instance FromJSON GenotypeDataSpec where
    parseJSON = withObject "GenotypeData" $ \v -> GenotypeDataSpec
        <$> v .: "format"
        <*> v .: "genoFile"
        <*> v .: "snpFile"
        <*> v .: "indFile"

instance ToJSON GenotypeDataSpec where
    -- this encodes directly to a bytestring Builder
    toJSON x = object [
        "format" .= format x,
        "genoFile" .= genoFile x,
        "snpFile" .= snpFile x,
        "indFile" .= indFile x
        ]

-- | A data type representing the options fo the genotype format
data GenotypeFormatSpec = GenotypeFormatEigenstrat
    | GenotypeFormatPlink
    deriving (Show, Eq)

-- | To facilitate automatic parsing of GenotypeFormatSpec from JSON files
instance FromJSON GenotypeFormatSpec where
    parseJSON = withText "format" $ \v -> case v of
        "EIGENSTRAT" -> pure GenotypeFormatEigenstrat
        "PLINK"      -> pure GenotypeFormatPlink
        _            -> fail ("unknown format " ++ T.unpack v)

instance ToJSON GenotypeFormatSpec where
    toJSON a = case a of
        GenotypeFormatPlink      -> "PLINK"
        GenotypeFormatEigenstrat -> "EIGENSTRAT"

zipAll :: MonadSafe m => [Int] -> [Producer (EigenstratSnpEntry, GenoLine) m r] -> Producer [(EigenstratSnpEntry, GenoLine)] m [r]
zipAll _                   []            = error "zipAll - should never happen (1)"
zipAll []                  _             = error "zipAll - should never happen (2)"
zipAll _                   [prod]        = fmap (\x -> [x]) (prod >-> orderCheckPipe compFunc1) >-> P.map (\x ->[x])
zipAll (nrHaps:restNrHaps) (prod1:prods) =
    fmap (\(r, rs) -> (r:rs)) (orderedZip compFunc2 (prod1 >-> orderCheckPipe compFunc1) (zipAll restNrHaps prods)) >-> P.map processMaybeTuples
  where
    processMaybeTuples :: (Maybe (EigenstratSnpEntry, GenoLine), Maybe [(EigenstratSnpEntry, GenoLine)]) -> [(EigenstratSnpEntry, GenoLine)]
    processMaybeTuples (Nothing,        Nothing)          = error "processMaybeTuples: should never happen"
    processMaybeTuples (Just (es, gl),  Nothing)          = (es, gl) : [(es, V.replicate l Missing) | l <- restNrHaps]
    processMaybeTuples (Nothing,        Just restEntries) = (fst (head restEntries), V.replicate nrHaps Missing) : restEntries
    processMaybeTuples (Just (es, gl1), Just restEntries) = (es, gl1) : restEntries

compFunc1 :: (EigenstratSnpEntry, GenoLine) -> (EigenstratSnpEntry, GenoLine) -> Ordering
compFunc1 (EigenstratSnpEntry c1 p1 _ _ _ _, _) (EigenstratSnpEntry c2 p2 _ _ _ _, _) = compare (c1, p1) (c2, p2)

compFunc2 :: (EigenstratSnpEntry, GenoLine) -> [(EigenstratSnpEntry, GenoLine)] -> Ordering
compFunc2 (EigenstratSnpEntry c1 p1 _ _ _ _, _) ((EigenstratSnpEntry c2 p2 _ _ _ _, _):_) = compare (c1, p1) (c2, p2)
compFunc2 _                                     []                                        = error "compFunc2 - should never happen"

-- | A function to return a list of all individuals in the genotype files of a package.
loadIndividuals :: GenotypeDataSpec -- ^ the Genotype spec
               -> IO [EigenstratIndEntry] -- ^ the returned list of EigenstratIndEntries.
loadIndividuals (GenotypeDataSpec format_ _ _ indF) =
    case format_ of
        GenotypeFormatEigenstrat -> readEigenstratInd indF
        GenotypeFormatPlink      -> readFamFile indF

-- | A function to read the genotype data of a package
loadGenotypeData :: (MonadSafe m) => GenotypeDataSpec -- ^ the genotype spec
                -> m ([EigenstratIndEntry], Producer (EigenstratSnpEntry, GenoLine) m ())
                -- ^ a pair of the EigenstratIndEntries and a Producer over the Snp position values and the genotype line.
loadGenotypeData (GenotypeDataSpec format_ genoF snpF indF) = do
    forM_ [genoF, snpF, indF] $ (\f -> do
        fileE <- liftIO (doesFileExist f)
        when (not fileE) $ throwM (PoseidonFileExistenceException ("File " ++ f ++ " does not exist")))
    case format_ of
        GenotypeFormatEigenstrat -> readEigenstrat genoF snpF indF
        GenotypeFormatPlink      -> readPlink genoF snpF indF

-- | A function to read genotype data jointly from multiple packages
loadJointGenotypeData :: (MonadSafe m) => Bool -- ^ whether to show all warnings
                     -> [GenotypeDataSpec] -- ^ A list of genotype specifications
                     -> m ([EigenstratIndEntry], Producer (EigenstratSnpEntry, GenoLine) m ())
                     -- ^ a pair of the EigenstratIndEntries and a Producer over the Snp position values and the genotype line, joined across all packages.
loadJointGenotypeData showAllWarnings gds = do
    genotypeTuples <- mapM loadGenotypeData gds
    let indEntries      = map fst genotypeTuples
        jointIndEntries = concat indEntries
        nrInds          = map length indEntries
        jointProducer   = (zipAll nrInds . map snd) genotypeTuples >-> P.mapM (joinEntries showAllWarnings)
    return (jointIndEntries, void jointProducer)

joinEntries :: (MonadSafe m) => Bool -> [(EigenstratSnpEntry, GenoLine)] -> m (EigenstratSnpEntry, GenoLine)
joinEntries showAllWarnings tupleList = do
    let allSnpEntries    = map fst tupleList
        allGenoEntries   = map snd tupleList
    snpEntry@(EigenstratSnpEntry _ _ _ _ refA altA) <- getConsensusSnpEntry showAllWarnings allSnpEntries
    recodedGenotypes <- forM (zip allSnpEntries allGenoEntries) $ \((EigenstratSnpEntry _ _ _ _ refA1 altA1), genoLine) ->
        genotypes2alleles refA1 altA1 genoLine >>= recodeAlleles refA altA
    return (snpEntry, V.concat recodedGenotypes)

getConsensusSnpEntry :: (MonadSafe m) => Bool -> [EigenstratSnpEntry] -> m EigenstratSnpEntry 
getConsensusSnpEntry showAllWarnings snpEntries = do
    let chrom = snpChrom . head $ snpEntries
        pos = snpPos . head $ snpEntries
        uniqueIds = nub . map snpId $ snpEntries
        uniqueGenPos = sort . nub . map snpGeneticPos $ snpEntries
        allAlleles    = concat $ [[r, a] | EigenstratSnpEntry _ _ _ _ r a <- snpEntries]
        uniqueAlleles = nub . filter (\a -> a /= 'N' && a /= '0' && a /= 'X') $ allAlleles
    id_ <- case uniqueIds of
        [i] -> return i
        _ -> do
            -- multiple Ids: Picking the first rs-number if possible, otherwise the first one.
            let rsIds = filter (isPrefixOf "rs") uniqueIds
                selectedId = case rsIds of
                    (i:_) -> i
                    _ -> head uniqueIds
            when showAllWarnings $ 
                liftIO . hPutStrLn stderr $ "Warning: Found inconsistent SNP IDs: " ++ show uniqueIds ++
                    ". Choosing " ++ show selectedId
            return selectedId
    genPos <- case uniqueGenPos of
        [p] -> return p
        [0.0, p] -> return p -- 0.0 is considered "no data" in genetic position column
        _ -> do
            -- multiple non-zero genetic positions. Choosing the largest one.
            let selectedGenPos = maximum uniqueGenPos
            when showAllWarnings $ 
                liftIO . hPutStrLn stderr $ "Warning: Found inconsistent genetic positions in SNP " ++ show id_ ++
                    ": " ++ show uniqueGenPos ++ ". Choosing " ++ show selectedGenPos
            return selectedGenPos
    case uniqueAlleles of
        [] -> do
            -- no non-missing alleles found
            when showAllWarnings $ 
                liftIO . hPutStrLn stderr $ "Warning: SNP " ++ show id_ ++ " appears to have no data (both ref and alt allele are blank"
            return (EigenstratSnpEntry chrom pos genPos id_ 'N' 'N')
        [r] -> do
            -- only one non-missing allele found
            when showAllWarnings $ 
                liftIO . hPutStrLn stderr $ "Warning: SNP " ++ show id_ ++ " appears to be monomorphic (only one of ref and alt alleles are non-blank)"
            return (EigenstratSnpEntry chrom pos genPos id_ 'N' r)
        [ref, alt] -> return (EigenstratSnpEntry chrom pos genPos id_ ref alt)
        _ -> throwM $ PoseidonGenotypeException ("Incongruent alleles: " ++ show snpEntries)

genotypes2alleles :: (MonadThrow m) => Char -> Char -> GenoLine -> m (V.Vector (Char, Char))
genotypes2alleles ref alt = V.mapM g2a
  where
    g2a :: (MonadThrow m) => GenoEntry -> m (Char, Char)
    g2a HomRef =
        if ref `notElem` na
        then return (ref, ref)
        else throwM (PoseidonGenotypeException "encountered illegal genotype Hom-Ref with Ref-Allele missing")
    g2a Het = 
        if ref `notElem` na && alt `notElem` na
        then return (ref, alt)
        else throwM (PoseidonGenotypeException "encountered illegal genotype Het with Ref-Allele or Alt-Allele missing")
    g2a HomAlt =
        if alt `notElem` na
        then return (alt, alt)
        else throwM (PoseidonGenotypeException "encountered illegal genotype Hom-Alt with Alt-Allele missing")
    g2a Missing = return ('N', 'N')
    na = ['0', 'N', 'X']
    
recodeAlleles :: (MonadThrow m) => Char -> Char -> V.Vector (Char, Char) -> m GenoLine
recodeAlleles ref alt = V.mapM a2g
  where
    a2g :: (MonadThrow m) => (Char, Char) -> m GenoEntry
    a2g (a1, a2)
        | (a1, a2)  == (ref, ref)                            && ref `notElem` na                       = return HomRef 
        | (a1, a2)  == (alt, alt)                            && alt `notElem` na                       = return HomAlt
        | ((a1, a2) == (ref, alt) || (a1, a2) == (alt, ref)) && (ref `notElem` na && alt `notElem` na) = return Het
        | a1 `elem` na && a2 `elem` na                                                                 = return Missing
        | otherwise                                                                                    = throwM (err a1 a2)
    err a1 a2 = PoseidonGenotypeException ("cannot recode allele-pair " ++ show (a1, a2) ++ " with ref,alt alleles " ++ show (ref, alt))
    na = ['0', 'N', 'X']
