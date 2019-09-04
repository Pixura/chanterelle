module Chanterelle.Internal.Types.Project where

import Prelude

import Chanterelle.Internal.Utils.Json (decodeJsonAddress, decodeJsonHexString, encodeJsonAddress, encodeJsonHexString, gfWithDecoder)
import Control.Alt ((<|>))
import Data.Argonaut (class EncodeJson, class DecodeJson, encodeJson, decodeJson, (:=), (~>), (.:), (.:!), (.!=), jsonEmptyObject)
import Data.Array (elem, filter, null)
import Data.Either (Either(..))
import Data.Maybe (Maybe, fromMaybe)
import Data.String (Pattern(..), joinWith, split)
import Data.Traversable (for)
import Data.Tuple (Tuple(..))
import Effect.Aff (Milliseconds)
import Foreign.Object as M
import Language.Solidity.Compiler.Types as ST
import Network.Ethereum.Web3 (Address, HexString)
import Node.Path (FilePath)
import Node.Path as Path

--------------------------------------------------------------------------------
-- | Chanterelle Project Types
--------------------------------------------------------------------------------

newtype Dependency = Dependency String

derive instance eqDependency  :: Eq Dependency

instance encodeJsonDependency :: EncodeJson Dependency where
  encodeJson (Dependency d) = encodeJson d

instance decodeJsonDependency :: DecodeJson Dependency where
  decodeJson d = Dependency <$> decodeJson d

---------------------------------------------------------------------

data InjectableLibraryCode = InjectableWithSourceCode (Maybe FilePath) FilePath
                           | InjectableWithBytecode HexString

derive instance eqInjectableLibraryCode :: Eq InjectableLibraryCode

instance encodeJsonInjectableLibraryCode :: EncodeJson InjectableLibraryCode where
  encodeJson (InjectableWithSourceCode r f) = encodeJson $ M.fromFoldable elems
    where elems = file <> root
          file  = [Tuple "file" $ encodeJson f]
          root  = fromMaybe [] (pure <<< Tuple "root" <<< encodeJson <$> r)
  encodeJson (InjectableWithBytecode c)   = encodeJson $ M.singleton "bytecode" (encodeJsonHexString c)

instance decodeJsonInjectableLibraryCode :: DecodeJson InjectableLibraryCode where
  decodeJson d = decodeSourceCode <|> decodeBytecode <|> Left "not a valid InjectableLibrarySource"
      where decodeSourceCode = decodeJson d >>= (\o -> InjectableWithSourceCode <$> o .:! "root" <*> o .: "file")
            decodeBytecode   = do
              o <- decodeJson d
              bc <- gfWithDecoder decodeJsonHexString o "bytecode"
              pure $ InjectableWithBytecode bc

data Library = FixedLibrary            { name :: String, address :: Address  }
             | FixedLibraryWithNetwork { name :: String, address :: Address, networks :: NetworkRefs }
             | InjectableLibrary       { name :: String, address :: Address, code :: InjectableLibraryCode }
             | DeployableLibrary       { name :: String, sourceRoot :: Maybe FilePath, sourceCode :: FilePath }

isFixedLibrary :: Library -> Boolean
isFixedLibrary (FixedLibrary _) = true
isFixedLibrary _                = false

newtype Libraries = Libraries (Array Library)

derive instance eqLibrary                  :: Eq Library
derive instance eqLibraries                :: Eq Libraries
derive newtype instance monoidLibraries    :: Monoid Libraries
derive newtype instance semigroupLibraries :: Semigroup Libraries

instance encodeJsonLibraries :: EncodeJson Libraries where
  encodeJson (Libraries libs) =
    let asAssocs = mkTuple <$> libs
        mkTuple (FixedLibrary l)            = Tuple l.name (encodeJsonAddress l.address)
        mkTuple (FixedLibraryWithNetwork l) = Tuple l.name $
                                                   "address" := encodeJsonAddress  l.address
                                                ~> "via"     := encodeJson l.networks
                                                ~> jsonEmptyObject
        mkTuple (InjectableLibrary l)       = Tuple l.name $
                                                   "address" := encodeJsonAddress l.address
                                                ~> "code"    := encodeJson l.code
                                                ~> jsonEmptyObject
        mkTuple (DeployableLibrary l)       = Tuple l.name $
                                                   "code" := encodeJson l.sourceCode
                                                ~> jsonEmptyObject
        asMap    = M.fromFoldable asAssocs
     in encodeJson asMap

instance decodeJsonLibraries :: DecodeJson Libraries where
  decodeJson j = do
    obj <- decodeJson j
    libs <- for (M.toUnfoldable obj) $ \t -> (decodeFixedLibrary t) <|> (decodeFixedLibraryWithNetwork t) <|> (decodeInjectableLibrary t) <|> (decodeDeployableLibrary t) <|> (failDramatically t)
    pure (Libraries libs)

    where decodeFixedLibrary (Tuple name l) = do
            address <- decodeJsonAddress l
            pure $ FixedLibrary { name, address }

          decodeFixedLibraryWithNetwork (Tuple name l) = do
            fln <- decodeJson l
            address <- gfWithDecoder decodeJsonAddress fln "address"
            networks <- fln .: "via"
            pure $ FixedLibraryWithNetwork { name, address, networks }

          decodeInjectableLibrary (Tuple name l) = do
            ilo <- decodeJson l
            address <- gfWithDecoder decodeJsonAddress ilo "address"
            code    <- ilo .: "code"
            pure $ InjectableLibrary { name, address, code }

          decodeDeployableLibrary (Tuple name l) = do 
            ilo <- decodeJson l
            libCode <- ilo .: "code"
            case libCode of
              InjectableWithSourceCode sourceRoot sourceCode -> pure $ DeployableLibrary { name, sourceRoot, sourceCode }
              _ -> Left ("Deployable library code for " <> name <> " may only be specified with source code")

          failDramatically (Tuple name _) = Left ("Malformed library descriptor for " <> name)

---------------------------------------------------------------------

data ChainSpec = AllChains
               | SpecificChains (Array String)
derive instance eqChainSpec :: Eq ChainSpec

networkIDFitsChainSpec :: ChainSpec -> String -> Boolean
networkIDFitsChainSpec AllChains _ = true
networkIDFitsChainSpec (SpecificChains chains) id = id `elem` chains

instance decodeJsonChainSpec :: DecodeJson ChainSpec where
  decodeJson j = decodeAllChains <|> decodeSpecificChains <|> Left "Invalid chain specifier"
    where decodeStr = decodeJson j
          decodeAllChains = decodeStr >>= (\s -> if s == "*" then Right AllChains else Left "Not * for AllChains")
          decodeSpecificChains = decodeStr >>= (\s -> SpecificChains <$> for (split (Pattern ",") s) pure)


instance encodeJsonChainSpec :: EncodeJson ChainSpec where
  encodeJson AllChains = encodeJson "*"
  encodeJson (SpecificChains c) = encodeJson $ joinWith "," c

newtype Network = Network { name :: String
                          , providerUrl :: String
                          , allowedChains :: ChainSpec
                          }
derive instance eqNetwork :: Eq Network

instance encodeJsonNetwork :: EncodeJson Network where
  encodeJson (Network n)     =  "url"    := n.providerUrl
                             ~> "chains" := n.allowedChains
                             ~> jsonEmptyObject

newtype Networks = Networks (Array Network)
derive instance eqNetworks                :: Eq Networks
derive newtype instance monoidNetworks    :: Monoid Networks
derive newtype instance semigroupNetworks :: Semigroup Networks

instance decodeJsonNetworks :: DecodeJson Networks where
  decodeJson j = decodeJson j >>= (\o -> Networks <$> for (M.toUnfoldable o) decodeNetwork)
    where decodeNetwork (Tuple name net) = do
            o <- decodeJson net
            providerUrl   <- o .: "url"
            allowedChains <- o .: "chains"
            pure $ Network { name, providerUrl, allowedChains }

instance encodeJsonNetworks :: EncodeJson Networks where
  encodeJson (Networks nets) = encodeJson $ M.fromFoldable (encodeNetwork <$> nets)
    where encodeNetwork (Network net) =  Tuple net.name $
                                            "url"    := net.providerUrl
                                        ~> "chains" := net.allowedChains
                                        ~> jsonEmptyObject

newtype NetworkRef = NetworkRef String
derive instance eqNetworkRef :: Eq NetworkRef
derive newtype instance decodeJsonNetworkRef :: DecodeJson NetworkRef
derive newtype instance encodeJsonNetworkRef :: EncodeJson NetworkRef
derive newtype instance monoidNetworkRef     :: Monoid NetworkRef
derive newtype instance semigroupNetworkRef  :: Semigroup NetworkRef

data NetworkRefs = AllNetworks        -- "**"
                 | AllDefinedNetworks -- "*"
                 | SpecificRefs (Array String)
derive instance eqNetworkRefs :: Eq NetworkRefs

instance decodeJsonNetworkRefs :: DecodeJson NetworkRefs where
  decodeJson j = (SpecificRefs <$> decodeJson j) <|> (decodeStringy =<< decodeJson j) <|> Left "Invalid NetworkRef"
    where decodeStringy = case _ of
            "*" -> Right AllDefinedNetworks
            "**" -> Right AllNetworks
            _ -> Left "Not * or **"

instance encodeJsonNetworkRefs :: EncodeJson NetworkRefs where
  encodeJson AllNetworks = encodeJson "**"
  encodeJson AllDefinedNetworks = encodeJson "*"
  encodeJson (SpecificRefs nets) = encodeJson $ encodeJson <$> nets

resolveNetworkRefs :: NetworkRefs -> Networks -> Networks
resolveNetworkRefs refs definedNets = case refs of
  AllNetworks -> Networks mergedNetworks
  AllDefinedNetworks -> definedNets
  SpecificRefs specRefs -> Networks $ filter (\(Network { name }) -> name `elem` specRefs) mergedNetworks

  where predefinedNets = [ Network { name: "mainnet", providerUrl: "https://mainnet.infura.io", allowedChains: SpecificChains ["1"] }
                         , Network { name: "ropsten", providerUrl: "https://ropsten.infura.io", allowedChains: SpecificChains ["3"] }
                         , Network { name: "rinkeby", providerUrl: "https://rinkeby.infura.io", allowedChains: SpecificChains ["4"] }
                         , Network { name: "kovan"  , providerUrl: "https://kovan.infura.io"  , allowedChains: SpecificChains ["42"] }
                         , Network { name: "localhost", providerUrl: "http://localhost:8545/", allowedChains: AllChains }
                         ]
        (Networks definedNets') = definedNets

        -- todo: don't n^2 this shit
        predefinedNetsWithoutOverrides = filter (\(Network predef) -> null (filter (\(Network def) -> predef.name == def.name) definedNets')) predefinedNets
        mergedNetworks = definedNets' <> predefinedNetsWithoutOverrides

---------------------------------------------------------------------

newtype SolcOptimizerSettings = SolcOptimizerSettings { enabled :: Boolean, runs :: Int }

derive instance eqSolcOptimizerSettings :: Eq SolcOptimizerSettings

instance encodeJsonSolcOptimizerSettings :: EncodeJson SolcOptimizerSettings where
  encodeJson (SolcOptimizerSettings sos) =
         "enabled" := encodeJson sos.enabled
      ~> "runs"    := encodeJson sos.runs
      ~> jsonEmptyObject

instance decodeJsonSolcOptimizerSettings :: DecodeJson SolcOptimizerSettings where
  decodeJson j = do
      obj <- decodeJson j
      enabled <- obj .:! "enabled" .!= default.enabled
      runs    <- obj .:! "runs"    .!= default.runs
      pure $ SolcOptimizerSettings { enabled, runs }

      where (SolcOptimizerSettings default) = defaultSolcOptimizerSettings

-- these defaults are from the example in solc docs
defaultSolcOptimizerSettings :: SolcOptimizerSettings
defaultSolcOptimizerSettings = SolcOptimizerSettings { enabled: false, runs: 200 }

---------------------------------------------------------------------

data ChanterelleModuleType = LibraryModule | ContractModule

instance showChanterelleModuleType :: Show ChanterelleModuleType where
  show LibraryModule = "libary module"
  show ContractModule = "contract module"

data ChanterelleModule =
  ChanterelleModule { moduleName      :: String
                    , solContractName :: String
                    , solPath         :: FilePath
                    , jsonPath        :: FilePath
                    , pursPath        :: FilePath
                    , moduleType      :: ChanterelleModuleType
                    }

newtype ChanterelleProjectSpec =
  ChanterelleProjectSpec { name                  :: String
                         , version               :: String
                         , sourceDir             :: FilePath
                         , artifactsDir          :: FilePath
                         , libArtifactsDir       :: FilePath
                         , modules               :: Array String
                         , dependencies          :: Array Dependency
                         , extraAbis             :: Maybe FilePath
                         , libraries             :: Libraries
                         , networks              :: Networks
                         , solcOutputSelection   :: Array String
                         , solcOptimizerSettings :: Maybe ST.OptimizerSettings
                         , solcEvmVersion        :: Maybe ST.EvmVersion
                         , psGen                 :: { exprPrefix   :: String
                                                    , modulePrefix :: String
                                                    , outputPath   :: String
                                                    }
                         }

derive instance eqChanterelleProjectSpec  :: Eq ChanterelleProjectSpec

instance encodeJsonChanterelleProjectSpec :: EncodeJson ChanterelleProjectSpec where
  encodeJson (ChanterelleProjectSpec project) =
         "name"                  := encodeJson project.name
      ~> "version"               := encodeJson project.version
      ~> "source-dir"            := encodeJson project.sourceDir
      ~> "artifacts-dir"         := encodeJson project.artifactsDir
      ~> "modules"               := encodeJson project.modules
      ~> "dependencies"          := encodeJson project.dependencies
      ~> "extra-abis"            := encodeJson project.dependencies
      ~> "libraries"             := encodeJson project.libraries
      ~> "networks"              := encodeJson project.networks
      ~> "solc-output-selection" := encodeJson project.solcOutputSelection
      ~> "solc-optimizer"        := encodeJson project.solcOptimizerSettings
      ~> "purescript-generator"  := psGenEncode
      ~> jsonEmptyObject

      where psGenEncode =  "output-path"       := encodeJson project.psGen.outputPath
                        ~> "expression-prefix" := encodeJson project.psGen.exprPrefix
                        ~> "module-prefix"     := encodeJson project.psGen.modulePrefix
                        ~> jsonEmptyObject

instance decodeJsonChanterelleProjectSpec :: DecodeJson ChanterelleProjectSpec where
  decodeJson j = do
    obj                   <- decodeJson j
    name                  <- obj .: "name"
    version               <- obj .: "version"
    sourceDir             <- obj .: "source-dir"
    artifactsDir          <- obj .:! "artifacts-dir" .!= "build"
    libArtifactsDir       <- obj .:! "library-artifacts-dir" .!= (Path.concat [artifactsDir, "libraries"])
    modules               <- obj .: "modules"
    dependencies          <- obj .:! "dependencies" .!= mempty
    extraAbis             <- obj .:! "extra-abis"
    libraries             <- obj .:! "libraries" .!= mempty
    networks              <- obj .:! "networks" .!= mempty
    solcOptimizerSettings <- obj .:! "solc-optimizer"
    solcOutputSelection   <- obj .:! "solc-output-selection" .!= mempty
    solcEvmVersion        <- obj .:! "solc-evm-version"
    psGenObj              <- obj .: "purescript-generator"
    psGenOutputPath       <- psGenObj .: "output-path"
    psGenExprPrefix       <- psGenObj .:! "expression-prefix" .!= ""
    psGenModulePrefix     <- psGenObj .:! "module-prefix" .!= ""
    let psGen = { exprPrefix: psGenExprPrefix, modulePrefix: psGenModulePrefix, outputPath: psGenOutputPath }
    pure $ ChanterelleProjectSpec { name, version, sourceDir, artifactsDir, libArtifactsDir, modules, dependencies, extraAbis, libraries, networks, solcEvmVersion, solcOptimizerSettings, solcOutputSelection, psGen }

data ChanterelleProject =
     ChanterelleProject { root        :: FilePath -- ^ parent directory containing chanterelle.json
                        , srcIn       :: FilePath -- ^ hydrated/absolute path of src dir (root + spec.sourceDir)
                        , jsonOut     :: FilePath -- ^ hydrated/absolute path of jsons dir
                        , psOut       :: FilePath -- ^ hydrated/absolute path of psGen (root + spec.psGen.outputPath)
                        , spec        :: ChanterelleProjectSpec -- ^ the contents of the chanterelle.json
                        , modules     :: Array ChanterelleModule
                        , libModules  :: Array ChanterelleModule 
                        , specModTime :: Milliseconds -- ^ timestamp of the last time the chanterelle project spec (chanterelle.)json was modified
                        }
