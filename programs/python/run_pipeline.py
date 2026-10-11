import os
import sys
import logging
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

BASE = Path(__file__).resolve().parent.parent
DATA = BASE / "data"
TABLES = ["account", "client", "disp", "district", "loan", "trans"]
INDEXES = [("account", "account_id"), ("client", "client_id"), ("disp", "account_id"),
           ("disp", "client_id"), ("loan", "account_id"), ("trans", "account_id"),
           ("trans", "trans_id")]

logging.basicConfig(filename=BASE / "pipeline.log", level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("pipeline")

password = os.environ.get("MYSQL_PASSWORD")
if not password:
    sys.exit("Set the MYSQL_PASSWORD environment variable first.")

engine = create_engine(URL.create("mysql+pymysql", username="root", password=password,
                                  host=os.environ.get("MYSQL_HOST", "localhost"),
                                  port=3306, database="staging"))


def find_file(name):
    for ext in (".csv", ".asc"):
        p = DATA / f"{name}{ext}"
        if p.exists():
            return p
    raise FileNotFoundError(f"No file for {name} in {DATA}")


def write_run_log(table, rows, status, err=None):
    with engine.begin() as conn:
        conn.execute(text("INSERT INTO run_log (table_name, rows_loaded, status, error_message) "
                          "VALUES (:t, :r, :s, :e)"),
                     {"t": table, "r": rows, "s": status, "e": err})


def load_staging():
    for t in TABLES:
        try:
            total = 0
            for i, chunk in enumerate(pd.read_csv(find_file(t), sep=";", chunksize=100_000,
                                                  low_memory=False)):
                chunk.to_sql(t, engine, if_exists="replace" if i == 0 else "append",
                             index=False, chunksize=10_000)
                total += len(chunk)
            write_run_log(t, total, "SUCCESS")
            logger.info("Loaded %s: %d rows", t, total)
            print(f"{t}: {total} rows loaded")
        except Exception as e:
            write_run_log(t, 0, "FAIL", str(e)[:500])
            logger.error("Failed loading %s: %s", t, e)
            raise


def build_indexes():
    for tbl, col in INDEXES:
        try:
            with engine.begin() as conn:
                conn.execute(text(f"CREATE INDEX idx_{tbl}_{col} ON staging.{tbl} ({col})"))
        except Exception as e:
            logger.warning("Index idx_%s_%s skipped: %s", tbl, col, e)


def procedures_exist():
    with engine.connect() as conn:
        n = conn.execute(text("SELECT COUNT(*) FROM information_schema.routines "
                              "WHERE routine_schema = 'reporting' AND routine_name = 'sp_run_all'")).scalar()
    return n > 0


def refresh_reporting():
    with engine.begin() as conn:
        conn.execute(text("DROP TABLE IF EXISTS reporting.dim_district"))
        conn.execute(text("""
            CREATE TABLE reporting.dim_district AS
            SELECT A1 AS district_id, A2 AS district_name, A3 AS region, A4 AS population,
                   A9 AS num_cities, A10 AS urban_ratio_pct, A11 AS avg_salary,
                   A12 AS unemployment_rate_1995, A13 AS unemployment_rate_1996,
                   A14 AS entrepreneurs_per_1000, A15 AS crimes_1995, A16 AS crimes_1996
            FROM staging.district"""))
        conn.execute(text("CALL reporting.sp_run_all()"))


def main():
    logger.info("Pipeline started")
    load_staging()
    build_indexes()
    if not procedures_exist():
        print("Staging is loaded. Now run sql/01_setup.sql in MySQL Workbench, then run this script again.")
        logger.info("Staging loaded; reporting setup SQL not yet run")
        return
    refresh_reporting()
    logger.info("Reporting refresh and DQ checks complete")
    print("Pipeline finished successfully")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        logger.exception("Pipeline failed")
        print(f"Pipeline FAILED: {e}")
        sys.exit(1)
