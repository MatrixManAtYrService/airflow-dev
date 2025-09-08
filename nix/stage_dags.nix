{ pkgs, lib, python }:

rec {
  # Function to create a DAG package for a specific region and environment
  mkDagPackage = { repo, region, environment }: pkgs.stdenv.mkDerivation rec {
    pname = "${region}-${environment}-dags";
    version = "1.0.0";
    src = repo;

    buildInputs = [ python pkgs.tree ];

    buildPhase = ''
      # Set up constants for the build - derive from region name instead of src path
      PROJECT_NAME=${region}_airflow
      PACKAGE_VERSION="1.0.0"
      GIT_HASH="nix-build"
      K8S_PROP="${environment}"

      # Export these as environment variables for setup_support.py
      export PROJECT_NAME PACKAGE_VERSION GIT_HASH K8S_PROP

      # Create constants.py with the required variables
      cat > constants.py << EOF
PROJECT_NAME = "$PROJECT_NAME"
PACKAGE_VERSION = "$PACKAGE_VERSION"  
GIT_HASH = "$GIT_HASH"
K8S_PROP = "$K8S_PROP"
EOF

      # Run setup_support.py to generate the load_all_dags.py file
      python setup_support.py

      # Create the main DAG file that will be placed in the dags folder
      cat > ''${PROJECT_NAME}_dag.py << EOF
from airflow import DAG
from ''${PROJECT_NAME} import load_all_dags
load_all_dags
EOF
    '';

    installPhase = ''
      mkdir -p $out/dags
      
      # Copy the generated DAG file to the dags directory
      cp ''${PROJECT_NAME}_dag.py $out/dags/
      
      # Copy the entire source package to make it importable
      mkdir -p $out/dags/src
      cp -r src/''${PROJECT_NAME} $out/dags/src/
      
      # Copy the requirements.txt if it exists
      if [ -f requirements.txt ]; then
        cp requirements.txt $out/dags/
      fi
      
      echo "DAG package built for ${region}-${environment}"
      echo "Contents of $out/dags:"
      ls -la $out/dags/
    '';
  };

  # Function to create all packages for a given set of regional repos
  mkAllDagPackages = { regionalRepos }: 
    let
      environments = [ "dev" "stage" "prod" ];
      
      # Helper function to create packages for one region
      mkRegionPackages = regionName: repo:
        lib.listToAttrs (map (env: {
          name = "${regionName}-${env}";
          value = mkDagPackage { 
            repo = repo; 
            region = regionName; 
            environment = env; 
          };
        }) environments);
    in
      lib.foldl (acc: regionConfig: 
        acc // (mkRegionPackages regionConfig.name regionConfig.repo)
      ) {} regionalRepos;
}