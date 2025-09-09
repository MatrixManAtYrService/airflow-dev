{
  pkgs, lib, python, pythonEnv
}:

let
  # A single app to set up Airflow from stdin
  setupScript = pkgs.writeShellApplication {
    name = "setup-airflow-from-stdin";
    runtimeInputs = [ pkgs.jq python pythonEnv ];

    text = ''
      set -euo pipefail
      echo "Setting up Airflow environment from stdin..."

      # Read variables from stdin
      VARIABLES_JSON=$(cat -)

      # If stdin was empty, default to empty JSON
      if [ -z "$VARIABLES_JSON" ]; then
          VARIABLES_JSON="{}"
      fi

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

      echo "✅ Environment setup complete!"
    '';
  };
in
{
  # This is now the main app
  airflow = {
    type = "app";
    program = "${setupScript}/bin/setup-airflow-from-stdin";
  };
}