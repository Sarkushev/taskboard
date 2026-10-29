# TaskBoard

TaskBoard is a compact учебное приложение for DevOps students built with FastAPI and PostgreSQL. It provides a REST API and a simple web UI for managing tasks.

## Features

- Create tasks
- View all tasks
- Update task status: `new`, `in_progress`, `done`
- Edit and delete tasks
- Store data in PostgreSQL
- Use REST API and browser UI

## Stack

- FastAPI
- SQLAlchemy 2
- PostgreSQL
- Jinja2 templates

## PostgreSQL setup

Create database and user manually in PostgreSQL:

```sql
CREATE DATABASE taskboard;
CREATE USER taskboard WITH PASSWORD 'taskboard';
GRANT ALL PRIVILEGES ON DATABASE taskboard TO taskboard;
```

The application uses this connection string in code:

```text
postgresql+psycopg://taskboard:taskboard@localhost:5432/taskboard
```

If you need another host, port, database, or password, change `database_url` in [app/config.py](/D:/IUCA/DevOps - 2026/project/app/config.py:1).

## Run locally

1. Create and activate a virtual environment.
2. Install dependencies:

```bash
pip install -r requirements.txt
```

3. Make sure PostgreSQL is running and the `taskboard` database exists.
4. Start the app:

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

The app will be available at:

- Web UI: `http://localhost:8000/`
- Swagger UI: `http://localhost:8000/docs`
- Healthcheck: `http://localhost:8000/api/health`

## Autostart on Linux server

Example `systemd` unit:

```ini
[Unit]
Description=TaskBoard FastAPI application
After=network.target postgresql.service

[Service]
User=www-data
WorkingDirectory=/opt/taskboard
ExecStart=/opt/taskboard/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
```

Then enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable taskboard
sudo systemctl start taskboard
```

## REST API examples

Create a task:

```bash
curl -X POST http://localhost:8000/api/tasks \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"Prepare monitoring lab\",\"description\":\"Set up Prometheus basics\",\"status\":\"new\"}"
```

Update status:

```bash
curl -X PATCH http://localhost:8000/api/tasks/1/status \
  -H "Content-Type: application/json" \
  -d "{\"status\":\"done\"}"
```

## Automated deployment

The whole deployment is automated with `deploy.sh` (POSIX sh). On a fresh Linux
machine run:

~~~
git clone <this repository>
cd taskboard
chmod +x deploy.sh
./deploy.sh
~~~

The script installs missing packages (git, python3, pip, venv, curl, PostgreSQL),
creates `.venv`, installs `requirements.txt`, starts PostgreSQL, creates the
`taskboard` database and user, starts the application with Uvicorn and checks
`/api/health`. It is safe to run repeatedly.

Main parameters can be overridden through environment variables, for example:
`APP_PORT=9000 ./deploy.sh` (database settings must match `app/config.py`).

After a successful run:

- Web UI: http://localhost:8000/
- Swagger: http://localhost:8000/docs
- Healthcheck: http://localhost:8000/api/health

Application log: `/tmp/taskboard.log`, PID file: `/tmp/taskboard.pid`.
