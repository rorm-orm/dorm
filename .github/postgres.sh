PGPASSWORD=password psql -h 127.0.0.1 -U username postgres -c 'DROP DATABASE db;' -c 'CREATE DATABASE db;' || true
