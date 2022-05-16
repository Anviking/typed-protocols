# ###########################################################################
#
# Hydra release jobset.
#
# The purpose of this file is to select jobs defined in default.nix and map
# them to all supported build platforms.
#
############################################################################

# The project sources
{ typed-protocols ? {
  outPath = ./.;
  rev = "abcdef";
}

# Function arguments to pass to the project
, projectArgs ? {
  inherit sourcesOverride;
  config = {
    allowUnfree = false;
    inHydra = true;
  };
  gitrev = typed-protocols.rev;
}

# The systems that the jobset will be built for.
, supportedSystems ? [
  "x86_64-linux"
  "x86_64-darwin"
]

# The systems used for cross-compiling (default: linux)
, supportedCrossSystems ? [
  (builtins.head supportedSystems)
]

# Cross compilation to Windows is currently only supported on linux.
, windowsBuild ? builtins.elem "x86_64-linux" supportedCrossSystems

  # A Hydra option
, scrubJobs ? true

, withProblematicWindowsTests ? false

  # Dependencies overrides
, sourcesOverride ? { }

  # Import pkgs, including IOHK common nix lib
, pkgs ? import ./nix { inherit sourcesOverride; }

}:

with (import pkgs.iohkNix.release-lib) {
  inherit pkgs;
  inherit supportedSystems supportedCrossSystems scrubJobs projectArgs;
  packageSet = import typed-protocols;
  gitrev = typed-protocols.rev;
};

with pkgs.lib;
let
  # restrict supported systems to a subset where tests (if exist) are required to pass:
  testsSupportedSystems =
    intersectLists supportedSystems [ "x86_64-linux" "x86_64-darwin" ];
  # Recurse through an attrset, returning all derivations in a list matching test supported systems.
  collectJobs' = ds:
    filter (d: elem d.system testsSupportedSystems) (collect isDerivation ds);
  # Adds the package name to the derivations for windows-testing-bundle.nix
  # (passthru.identifier.name does not survive mapTestOn)
  collectJobs = ds:
    concatLists (mapAttrsToList (packageName: package:
      map (drv: drv // { inherit packageName; }) (collectJobs' package)) ds);

  nonDefaultBuildSystems = tail supportedSystems;

  # Paths or prefixes of paths of derivations to build only on the default system (ie. linux on hydra):
  onlyBuildOnDefaultSystem = [ [ ] ];
  # Paths or prefix of paths for which cross-builds (mingwW64, musl64) are disabled:
  noCrossBuild = let
    # checks are available from two path:
    checksPaths = path: [
      ([ "checks" "tests" ] ++ path)
      ([ "haskellPackages" (head path) "checks" ] ++ (tail path))
    ];
    # as well as tests:
    testsPaths = path: [
      ([ "tests" ] ++ path)
      ([ "haskellPackages" (head path) "components" "tests" ] ++ (tail path))
    ];
    # as well as exes:
    exesPaths = path: [
      ([ "exes" ] ++ path)
      ([ "haskellPackages" (head path) "components" "exes" ] ++ (tail path))
    ];
    stylePaths = path: [
      ([ "checks" "styles" ] ++ path)
      ([ "haskellPackages" (head path) "checks" ] ++ (tail path))
    ];
  in [ [ "shell" ] ] ++ (optionals (!withProblematicWindowsTests)
    (checksPaths [ "typed-protocols-examples" "test" ]))
  ++ (stylePaths [ "check-nixfmt" "check-stylish" ])
  ++ onlyBuildOnDefaultSystem;

  # Remove build jobs for which cross compiling does not make sense.
  filterProject = noBuildList:
    mapAttrsRecursiveCond (a: !(isDerivation a)) (path: value:
      if (isDerivation value
        && (any (p: take (length p) path == p) noBuildList)) then
        null
      else
        value) project;

  inherit (systems.examples) mingwW64 musl64;

  jobs = {
    native = let
      filteredBuilds = mapAttrsRecursiveCond (a: !(isList a)) (path: value:
        if (any (p: take (length p) path == p) onlyBuildOnDefaultSystem) then
          filter (s: !(elem s nonDefaultBuildSystems)) value
        else
          value) (packagePlatforms project);
    in (mapTestOn (__trace (__toJSON filteredBuilds) filteredBuilds));
    # TODO: fix broken evals
    #musl64 = mapTestOnCross musl64 (packagePlatformsCross project);
  } // (optionalAttrs windowsBuild {
    "${mingwW64.config}" = mapTestOnCross mingwW64
      (packagePlatformsCross (filterProject noCrossBuild));
  }) // (mkRequiredJob (concatLists [
    (collectJobs jobs."${mingwW64.config}".checks.tests)
    (collectJobs jobs.native.checks)
    (collectJobs jobs.native.benchmarks)
    (collectJobs jobs.native.libs)
    (collectJobs jobs.native.exes)
  ])) // {
    # This is used for testing the build on windows.
    io-sim-tests-win64 = pkgs.callPackage ./nix/windows-testing-bundle.nix {
      inherit project;
      tests = collectJobs jobs."${mingwW64.config}".tests;
      benchmarks = collectJobs jobs."${mingwW64.config}".benchmarks;
    };
  };

in jobs
