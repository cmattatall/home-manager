# Use libpq's password prompt, ~/.pgpass, or externally supplied PGPASSWORD.
# Never embed database credentials in this file or the Nix store.
psql_local() {
    local db=${1:-resources}
    psql -h localhost -p 5432 -U postgres -d "$db"
}

psql_local_exec () {
    psql -h localhost -p 5432 -U postgres -d resources -c "$*"
}
