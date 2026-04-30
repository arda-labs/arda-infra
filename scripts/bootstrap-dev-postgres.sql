\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mdm') THEN
    CREATE ROLE mdm LOGIN PASSWORD 'mdm@123';
  ELSE
    ALTER ROLE mdm LOGIN PASSWORD 'mdm@123';
  END IF;
END
$$;

SELECT 'CREATE DATABASE mdm OWNER mdm'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'mdm')\gexec

ALTER DATABASE mdm OWNER TO mdm;

GRANT ALL PRIVILEGES ON DATABASE mdm TO mdm;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'notification') THEN
    CREATE ROLE notification LOGIN PASSWORD 'notification@123';
  ELSE
    ALTER ROLE notification LOGIN PASSWORD 'notification@123';
  END IF;
END
$$;

SELECT 'CREATE DATABASE notification OWNER notification'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'notification')\gexec

ALTER DATABASE notification OWNER TO notification;

GRANT ALL PRIVILEGES ON DATABASE notification TO notification;
