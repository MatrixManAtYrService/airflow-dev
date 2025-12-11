from datetime import datetime

from airflow import DAG
from airflow.datasets import Dataset
from airflow.operators.empty import EmptyOperator
from billing_na_airflow.shared.common.na_dag import na_dag
from billing_na_airflow.shared.common.na_dag_config import NaDagConfig

from clover_billing.shared.common.processing_group import processing_group
from clover_billing.shared.common.processing_group_config import ProcessingGroupConfig

epoch = datetime(1970,1,1)
starting_gun = Dataset("starting_gun")

with DAG(
    dag_id="ready_set_go",
    schedule=starting_gun,
    start_date=epoch,
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=False
):
    EmptyOperator(task_id="go", outlets=starting_gun)

def make_worker(n: int) -> DAG:

    # Processing Group: CA Processing Group --> Resellers: CA
    TARGET_ENVIRONMENT = "whatif"
    PROCESSING_GROUP_BILLING_ENTITY = f"{n:026}"
    HIERARCHY_TYPE = "MERCHANT_SCHEDULE"

    config = ProcessingGroupConfig(
        PROCESSING_GROUP_BILLING_ENTITY,
        HIERARCHY_TYPE,
        "dev::" + TARGET_ENVIRONMENT,
        {}
    )

    # Enabled config
    config.disableCellular = False
    config.disableApp = False
    config.disableMisc = False
    config.disableValidators = False

    # Disabled config
    config.disableWaits = True
    config.disableInitWait = True
    config.disableJobStatusWait = True

    na_config = NaDagConfig(
        PROCESSING_GROUP_BILLING_ENTITY,
        HIERARCHY_TYPE,
        TARGET_ENVIRONMENT
    )

    na_config.disableFlightChecks = False
    na_config.disablePeriodCharge = True

    na_config.flight_checks_to_exclude = [
        "Check SFTP Connection.ODESSA"
    ]

    return na_dag(
        processing_group(
            DAG(
                dag_id=f"worker_{n:02}",
                schedule=starting_gun,
                start_date=epoch,
                catchup=False,
                max_active_runs=1,
                is_paused_upon_creation=False,
                default_args={
                    'retries': 0
                }
            ),
            config
        ),
        na_config
    )

workers = [make_worker(n) for n in range(99)]
