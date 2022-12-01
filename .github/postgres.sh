PGPASSWORD=password psql -U username db -c 'DROP DATABASE db;' -c 'CREATE DATABASE db;' || true
