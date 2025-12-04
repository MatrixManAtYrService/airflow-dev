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

      # Create admin user with password "admin"
      echo "Creating admin user..."
      airflow users create \
        --username admin \
        --password admin \
        --firstname Admin \
        --lastname User \
        --role Admin \
        --email admin@localhost

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

      # Set up dags directory structure:
      # - airflow_home/dags/ is a normal directory (mutable, for your own DAGs)
      # - airflow_home/dags/packaged_dags is a symlink to the nix store
      DagsDir="$AIRFLOW_HOME_DIR/dags"
      PackagedDagsLink="$DagsDir/packaged_dags"

      mkdir -p "$DagsDir"

      # Manage the packaged_dags symlink
      if [ -e "$PackagedDagsLink" ]; then
        if [ -L "$PackagedDagsLink" ]; then
          rm -f "$PackagedDagsLink"
        else
          echo "Error: $PackagedDagsLink exists but is not a symlink." >&2
          echo "Please remove it manually and re-run." >&2
          exit 1
        fi
      fi

      ln -s "$(pwd)/result/dags" "$PackagedDagsLink"

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