{ pkgs, lib, python }:

rec {
  # Function to create a DAG package for a specific region and environment
  mkDagPackage = { repo, region, environment, connections ? {}, variables ? {}, packageDags ? true, override_dags ? null }: pkgs.stdenv.mkDerivation rec {
    pname = "${region}-${environment}-dags";
    version = "1.0.0";
    src = repo;

    buildInputs = [ python pkgs.tree ];

    connectionsFile = pkgs.writeText "connections.json" (builtins.toJSON connections);
    variablesFile = pkgs.writeText "variables.json" (builtins.toJSON variables);
    
    PACKAGE_DAGS = if packageDags then "true" else "false";

    buildPhase = ''
      if [ "$PACKAGE_DAGS" = "true" ]; then
        echo "Packaging DAGs for ${pname}"
        # Set up constants for the build - map region to correct project name
        case "${region}" in
          "na") PROJECT_NAME="billing_na_airflow" ;;
          "emea") PROJECT_NAME="billing_emea_airflow" ;;
          "apac") PROJECT_NAME="billing_apac_airflow" ;;
          *) PROJECT_NAME="${region}_airflow" ;;
        esac
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
      else
        echo "Skipping DAG packaging for ${pname}"
      fi
    '';

    installPhase = ''
      mkdir -p $out/dags

      if [ "$PACKAGE_DAGS" = "true" ]; then
        # Copy the generated DAG file to the dags directory
        cp ''${PROJECT_NAME}_dag.py $out/dags/
        
        # Copy the entire source package to make it importable
        mkdir -p $out/dags/src
        cp -r src/''${PROJECT_NAME} $out/dags/src/

        # Create a .airflowignore file in the src directory to prevent duplicate DAG loading
        echo "dev" > $out/dags/src/''${PROJECT_NAME}/.airflowignore
        echo "prod" >> $out/dags/src/''${PROJECT_NAME}/.airflowignore
        echo "stage" >> $out/dags/src/''${PROJECT_NAME}/.airflowignore
        
        # Copy the requirements.txt if it exists
        if [ -f requirements.txt ]; then
          cp requirements.txt $out/dags/
        fi
        
        echo "DAG package built for ${region}-${environment}"
        echo "Contents of $out/dags:"
        ls -la $out/dags/
      else
        echo "No packaged DAGs for this environment." > $out/dags/README.md
      fi

      # If connections are defined, copy them into the output.
      if [ "$(cat ${connectionsFile})" != "{}" ]; then
        cp ${connectionsFile} $out/connections.json
      fi
      
      # If variables are defined, copy them into the output.
      if [ "$(cat ${variablesFile})" != "{}" ]; then
        cp ${variablesFile} $out/variables.json
      fi

      # If override_dags is set, write its path to a file.
      ${lib.optionalString (override_dags != null) ''
        echo "${override_dags}" > $out/override_dags.path
      ''}
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