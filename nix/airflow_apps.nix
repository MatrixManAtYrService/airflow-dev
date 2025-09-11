{
  pkgs, lib, python, pythonEnv, nix, regionalAirflowPkgs
}:

let
  # A single app to set up Airflow from stdin
  setupScript = pkgs.writeShellApplication {
    name = "setup-airflow-from-stdin";
    runtimeInputs = [ pkgs.jq python pythonEnv nix ] ++ regionalAirflowPkgs;

    text = ''
      set -euo pipefail
      echo "Setting up Airflow environment from stdin..."

      # Read the combined JSON from stdin
      INPUT_JSON=$(cat -)

      # If stdin was empty, exit
      if [ -z "$INPUT_JSON" ]; then
          echo "Error: Input JSON is empty." >&2
          exit 1
      fi

      # Extract variables and environment
      VARIABLES_JSON=$(echo "$INPUT_JSON" | jq '.variables')
      ENV_NAME=$(echo "$INPUT_JSON" | jq -r '.env')

      # Set up airflow home directory
      AIRFLOW_HOME_DIR="$(pwd)/airflow_home"
      export AIRFLOW_HOME="$AIRFLOW_HOME_DIR"
      mkdir -p "$AIRFLOW_HOME_DIR"

      # Clean up and init DB
      if [ -f "$AIRFLOW_HOME_DIR/airflow.db" ]; then
        echo "Removing existing Airflow database..."
        rm -f "$AIRFLOW_HOME_DIR/airflow.db"
      fi
      DB_INIT_CMD="airflow db init"
      echo "Executing: $DB_INIT_CMD"
      eval "$DB_INIT_CMD"

      # Set variables
      echo "Setting Airflow variables..."
      echo "$VARIABLES_JSON" | jq -r 'keys_unsorted[]' | while IFS= read -r key; do
        value=$(echo "$VARIABLES_JSON" | jq -r --arg key "$key" '.[$key]')
        echo "--> Setting variable: '$key'"
        airflow variables set "$key" "$value"
      done
      
      # Build and stage the dags for the specified environment
      echo "Building and staging DAGs for environment: $ENV_NAME"
      nix build ".#$ENV_NAME" --out-link result

      # Manage the dags symlink
      DagsLinkPath="$AIRFLOW_HOME_DIR/dags"
      if [ -e "$DagsLinkPath" ]; then
        if [ -L "$DagsLinkPath" ]; then
          rm -f "$DagsLinkPath"
        else
          echo "Error: $DagsLinkPath is a directory, not a symlink." >&2
          echo "Please fix this by running:" >&2
          echo "  sudo rm -rf $DagsLinkPath" >&2
          echo "Then re-run the prep-airflow command." >&2
          exit 1
        fi
      fi
      
      ln -s "$(pwd)/result/dags" "$DagsLinkPath"

      echo "✅ Environment setup complete!"
    '';
  };
in
{
  # This is now the main app
  prep-airflow = {
    type = "app";
    program = "${setupScript}/bin/setup-airflow-from-stdin";
  };
}