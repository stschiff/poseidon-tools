{-# LANGUAGE OverloadedStrings #-}

import           Paths_poseidon_hs      (version)
import           Poseidon.CLI.FStats    (FStatSpec (..), FstatsOptions (..),
                                        JackknifeMode (..), fStatSpecParser,
                                        runFstats, runParser)
import           Poseidon.GenotypeData  (GenotypeFormatSpec (..))
import           Poseidon.CLI.Init      (InitOptions (..), runInit)
import           Poseidon.CLI.List      (ListEntity (..), ListOptions (..),
                                        runList)
import           Poseidon.CLI.Forge     (ForgeOptions (..), runForge)
import           Poseidon.ForgeRecipe   (ForgeEntity (..),
                                        forgeEntitiesParser)
import           Poseidon.CLI.Summarise (SummariseOptions(..), runSummarise)
import           Poseidon.CLI.Survey    (SurveyOptions(..), runSurvey)
import           Poseidon.CLI.Validate  (ValidateOptions(..), runValidate)

import           Control.Applicative    ((<|>))
import           Data.ByteString.Char8  (pack, splitWith)
import           Data.Version           (showVersion)
import qualified Options.Applicative    as OP
import           SequenceFormats.Utils  (Chrom (..))
import           Text.Read              (readEither)


data Options = CmdFstats FstatsOptions
    | CmdInit InitOptions
    | CmdList ListOptions
    | CmdForge ForgeOptions
    | CmdSummarise SummariseOptions
    | CmdSurvey SurveyOptions
    | CmdValidate ValidateOptions

main :: IO ()
main = do
    cmdOpts <- OP.customExecParser p optParserInfo
    case cmdOpts of
        CmdFstats opts    -> runFstats opts
        CmdInit opts      -> runInit opts
        CmdList opts      -> runList opts
        CmdForge opts     -> runForge opts
        CmdSummarise opts -> runSummarise opts
        CmdSurvey opts    -> runSurvey opts
        CmdValidate opts  -> runValidate opts
    where
        p = OP.prefs OP.showHelpOnEmpty

optParserInfo :: OP.ParserInfo Options
optParserInfo = OP.info (OP.helper <*> versionOption <*> optParser) (
    OP.briefDesc <>
    OP.progDesc "trident is a management and analysis tool for Poseidon packages. \
                \More information: \
                \https://github.com/poseidon-framework/poseidon-hs. \
                \Report issues: \
                \https://github.com/poseidon-framework/poseidon-hs/issues"
    )

versionOption :: OP.Parser (a -> a)
versionOption = OP.infoOption (showVersion version) (OP.long "version" <> OP.help "Show version")

optParser :: OP.Parser Options
optParser = OP.subparser (
        OP.command "list" listOptInfo <>
        OP.command "summarise" summariseOptInfo <>
        OP.command "survey" surveyOptInfo <>
        OP.command "validate" validateOptInfo <>
        OP.commandGroup "Package inspection commands:"
    ) <|>
    OP.subparser (
        OP.command "init" initOptInfo <>
        OP.command "forge" forgeOptInfo <>
        OP.commandGroup "Package manipulation commands:"
    ) <|>
    OP.subparser (
        OP.command "fstats" fstatsOptInfo <>
        OP.commandGroup "Analysis commands:"
    )


    
    

  where
    fstatsOptInfo = OP.info (OP.helper <*> (CmdFstats <$> fstatsOptParser))
        (OP.progDesc "Run fstats on groups and invidiuals within and across Poseidon packages")
    initOptInfo = OP.info (OP.helper <*> (CmdInit <$> initOptParser))
        (OP.progDesc "Create a new Poseidon package from genotype data")
    listOptInfo = OP.info (OP.helper <*> (CmdList <$> listOptParser))
        (OP.progDesc "List packages, groups or individuals")
    forgeOptInfo = OP.info (OP.helper <*> (CmdForge <$> forgeOptParser))
        (OP.progDesc "Select packages, groups or individuals and create a new Poseidon package from them")
    summariseOptInfo = OP.info (OP.helper <*> (CmdSummarise <$> summariseOptParser))
        (OP.progDesc "Get an overview over the content of one or multiple Poseidon packages")
    surveyOptInfo = OP.info (OP.helper <*> (CmdSurvey <$> surveyOptParser))
        (OP.progDesc "Survey the degree of context information completeness for Poseidon packages")
    validateOptInfo = OP.info (OP.helper <*> (CmdValidate <$> validateOptParser))
        (OP.progDesc "Check one or multiple Poseidon packages for structural correctness")

fstatsOptParser :: OP.Parser FstatsOptions
fstatsOptParser = FstatsOptions <$> parseBasePaths
                                <*> parseJackknife
                                <*> parseExcludeChroms
                                <*> OP.many parseStatSpecsDirect
                                <*> parseStatSpecsFromFile
                                <*> parseRawOutput

initOptParser :: OP.Parser InitOptions
initOptParser = InitOptions <$> parseInGenotypeFormat
                            <*> parseInGenoFile
                            <*> parseInSnpFile
                            <*> parseInIndFile
                            <*> parseOutPackagePath
                            <*> parseOutPackageName

listOptParser :: OP.Parser ListOptions
listOptParser = ListOptions <$> parseBasePaths <*> parseListEntity <*> parseRawOutput

forgeOptParser :: OP.Parser ForgeOptions
forgeOptParser = ForgeOptions <$> parseBasePaths
                              <*> parseForgeEntitiesDirect
                              <*> parseForgeEntitiesFromFile
                              <*> parseOutPackagePath
                              <*> parseOutPackageName
                              <*> parseShowWarnings

summariseOptParser :: OP.Parser SummariseOptions
summariseOptParser = SummariseOptions <$> parseBasePaths
                                      <*> parseRawOutput

surveyOptParser :: OP.Parser SurveyOptions
surveyOptParser = SurveyOptions <$> parseBasePaths
                                <*> parseRawOutput

validateOptParser :: OP.Parser ValidateOptions
validateOptParser = ValidateOptions <$> parseBasePaths -- <*> parseIgnoreGeno

-- parseIgnoreGeno :: OP.Parser Bool
-- parseIgnoreGeno = OP.switch (OP.long "ignoreGeno" <> OP.help "...")

parseJackknife :: OP.Parser JackknifeMode
parseJackknife = OP.option (OP.eitherReader readJackknifeString) (OP.long "jackknife" <> OP.short 'j' <>
    OP.help "Jackknife setting. If given an integer number, this defines the block size in SNPs. \
        \Set to \"CHR\" if you want jackknife blocks defined as entire chromosomes. The default is at 5000 SNPs" <> OP.value (JackknifePerN 5000))
  where
    readJackknifeString :: String -> Either String JackknifeMode
    readJackknifeString s = case s of
        "CHR"  -> Right JackknifePerChromosome
        numStr -> let num = readEither numStr
                  in  case num of
                        Left e  -> Left e
                        Right n -> Right (JackknifePerN n)

parseExcludeChroms :: OP.Parser [Chrom]
parseExcludeChroms = OP.option (map Chrom . splitWith (==',') . pack <$> OP.str) (OP.long "excludeChroms" <> OP.short 'e' <>
    OP.help "List of chromosome names to exclude chromosomes, given as comma-separated \
        \list. Defaults to X, Y, MT, chrX, chrY, chrMT, 23,24,90" <> OP.value [Chrom "X", Chrom "Y", Chrom "MT",
        Chrom "chrX", Chrom "chrY", Chrom "chrMT", Chrom "23", Chrom "24", Chrom "90"])

parseStatSpecsDirect :: OP.Parser FStatSpec
parseStatSpecsDirect = OP.option (OP.eitherReader readStatSpecString) (OP.long "stat" <>
    OP.help "Specify a summary statistic to be computed. Can be given multiple times. \
        \Possible options are: F4(name1, name2, name3, name4), and similarly F3 and F2 stats, \
        \as well as PWM(name1,name2) for pairwise mismatch rates. Group names are by default \
        \matched with group names as indicated in the PLINK or Eigenstrat files in the Poseidon dataset. \
        \You can also specify individual names using the syntax \"<Ind_name>\", so enclosing them \
        \in angular brackets. You can also mix groups and individuals, like in \
        \\"F4(<Ind1>,Group2,Group3,<Ind4>)\". Group or individual names are separated by commas, and a comma \
        \can be followed by any number of spaces, as in some of the examples in this help text.")

parseStatSpecsFromFile :: OP.Parser (Maybe FilePath)
parseStatSpecsFromFile = OP.option (Just <$> OP.str) (OP.long "statFile" <> OP.help "Specify a file with F-Statistics specified \
    \similarly as specified for option --stat. One line per statistics, and no new-line at the end" <> OP.value Nothing)

readStatSpecString :: String -> Either String FStatSpec
readStatSpecString s = case runParser fStatSpecParser () "" s of
    Left p  -> Left (show p)
    Right x -> Right x

parseForgeEntitiesDirect :: OP.Parser [ForgeEntity]
parseForgeEntitiesDirect = OP.option (OP.eitherReader readForgeEntitiesString) (OP.long "forgeString" <>
    OP.short 'f' <>
    OP.value [] <>
    OP.help "List of packages, groups or individual samples that should be in the newly forged package. \
        \Packages follow the syntax *package_title*, populations/groups are simply group_id and individuals \
        \<individual_id>. You can combine multiple values with comma, so for example: \
        \\"*package_1*, <individual_1>, <individual_2>, group_1\"")

parseForgeEntitiesFromFile :: OP.Parser (Maybe FilePath)
parseForgeEntitiesFromFile = OP.option (Just <$> OP.str) (OP.long "forgeFile" <>
    OP.value Nothing <>
    OP.help "A file with packages, groups or individual samples that should be in the newly forged package. \
    \Works just as -f, but multiple values can also be separated by newline, not just by comma. \
    \-f and --forgeFile can be combined.")

readForgeEntitiesString :: String -> Either String [ForgeEntity]
readForgeEntitiesString s = case runParser forgeEntitiesParser () "" s of
    Left p  -> Left (show p)
    Right x -> Right x

parseBasePaths :: OP.Parser [FilePath]
parseBasePaths = OP.some (OP.strOption (OP.long "baseDir" <>
    OP.short 'd' <>
    OP.metavar "DIR" <>
    OP.help "a base directory to search for Poseidon Packages (could be a Poseidon repository)"))

parseInGenotypeFormat :: OP.Parser GenotypeFormatSpec
parseInGenotypeFormat = OP.option (OP.eitherReader readGenotypeFormat) (OP.long "inFormat" <>
    OP.help "the format of the input genotype data: EIGENSTRAT or PLINK") 
    where
    readGenotypeFormat :: String -> Either String GenotypeFormatSpec
    readGenotypeFormat s = case s of
        "EIGENSTRAT" -> Right GenotypeFormatEigenstrat
        "PLINK"      -> Right GenotypeFormatPlink
        _            -> Left "must be EIGENSTRAT or PLINK"

parseInGenoFile :: OP.Parser FilePath
parseInGenoFile = OP.strOption (OP.long "genoFile" <>
    OP.help "the input geno file path")

parseInSnpFile :: OP.Parser FilePath
parseInSnpFile = OP.strOption (OP.long "snpFile" <>
    OP.help "the input snp file path")

parseInIndFile :: OP.Parser FilePath
parseInIndFile = OP.strOption (OP.long "indFile" <>
    OP.help "the input ind file path")

parseOutPackagePath :: OP.Parser FilePath
parseOutPackagePath = OP.strOption (OP.long "outPackagePath" <>
    OP.short 'o' <>
    OP.help "the output package directory path")

parseOutPackageName :: OP.Parser FilePath
parseOutPackageName = OP.strOption (OP.long "outPackageName" <>
    OP.short 'n' <>
    OP.help "the output package name")

parseShowWarnings :: OP.Parser Bool
parseShowWarnings = OP.switch (OP.long "warnings" <> OP.short 'w' <> OP.help "Show all warnings for merging genotype data")

parseListEntity :: OP.Parser ListEntity
parseListEntity = parseListPackages <|> parseListGroups <|> parseListIndividuals
  where
    parseListPackages = OP.flag' ListPackages (OP.long "packages" <> OP.help "list packages")
    parseListGroups = OP.flag' ListGroups (OP.long "groups" <> OP.help "list groups")
    parseListIndividuals = OP.flag' ListIndividuals (OP.long "individuals" <> OP.help "list individuals")

parseRawOutput :: OP.Parser Bool
parseRawOutput = OP.switch (OP.long "raw" <> OP.short 'r' <> OP.help "output table as tsv without header. Useful for piping into grep or awk.")


