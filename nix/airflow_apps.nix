{ pkgs, lib, python, dagPackages, pythonEnv }:

let
  # Create an app for setting up an Airflow environment
  mkAirflowApp = envName: envConfig: 
    let
      script = pkgs.writeShellApplication {
        name = "setup-${envName}";
        runtimeInputs = with pkgs; [ 
          (google-cloud-sdk.withExtraComponents [
            google-cloud-sdk.components.gke-gcloud-auth-plugin
          ])
          jq 
          python
          pythonEnv
        ];
        
        text = ''
        set -euo pipefail
        export USE_GKE_GCLOUD_AUTH_PLUGIN="True"
        
        echo "Setting up Airflow environment: ${envName}"
        
        # Build the DAGs
        echo "Building DAGs..."
        nix build .#${envName}
        
        # Set up airflow home directory
        AIRFLOW_HOME_DIR="$(pwd)/airflow_home"
        export AIRFLOW_HOME="$AIRFLOW_HOME_DIR"
        
        # Clean up existing setup
        if [ -f "$AIRFLOW_HOME_DIR/airflow.db" ]; then
          echo "Removing existing Airflow database..."
          rm -f "$AIRFLOW_HOME_DIR/airflow.db"
        fi
        
        # Create airflow_home directory structure
        mkdir -p "$AIRFLOW_HOME_DIR"
        
        # Create symlink to DAGs
        if [ -L "$AIRFLOW_HOME_DIR/dags" ]; then
          rm "$AIRFLOW_HOME_DIR/dags"
        fi
        ln -sf "$(pwd)/result/dags" "$AIRFLOW_HOME_DIR/dags"
        
        # Get environment configuration from gcloud
        echo "Fetching Airflow variables from Google Cloud Composer..."
        GCLOUD_CMD="gcloud composer environments run ${envConfig} variables export -- -"
        
        echo "Running: $GCLOUD_CMD"
        VARIABLES_JSON=$(eval "$GCLOUD_CMD" 2>/dev/null || echo "{}")
        
        # Store variables in file
        echo "$VARIABLES_JSON" > "$AIRFLOW_HOME_DIR/variables.json"
        echo "Variables saved to $AIRFLOW_HOME_DIR/variables.json"
        
        # Initialize Airflow database
        echo "Initializing Airflow database..."
        airflow db init
        
        # Set variables in Airflow
        echo "Setting Airflow variables..."
        if [ "$VARIABLES_JSON" != "{}" ]; then
          echo "$VARIABLES_JSON" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r key value; do
            echo "Setting variable: $key"
            airflow variables set "$key" "$value"
          done
        else
          echo "No variables to set (gcloud command may have failed)"
        fi
        
        echo ""
        echo "✅ Environment setup complete!"
        echo "📁 AIRFLOW_HOME: $AIRFLOW_HOME"
        echo "📁 DAGs directory: $AIRFLOW_HOME/dags"
        echo "📁 Variables file: $AIRFLOW_HOME/variables.json"
        echo ""
        echo "You can now run Airflow commands like:"
        echo "  airflow webserver"
        echo "  airflow scheduler" 
        echo "  airflow dags list"
      '';
    };
    in {
      type = "app";
      program = "${script}/bin/setup-${envName}";
    };

  # Read environments.json and create apps
  environmentsJson = builtins.fromJSON (builtins.readFile ../environments.json);
  
in
{
  # Create all apps based on environments.json
  mkAllAirflowApps = lib.mapAttrs mkAirflowApp environmentsJson;
}