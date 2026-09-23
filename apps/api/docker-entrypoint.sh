#!/bin/sh
# Container entrypoint.
#
# One image, three jobs — serve, migrate, seed — so the thing that runs the migration is
# byte-identical to the thing that will serve the traffic. A separate migration image drifts
# from the app image, and the drift shows up as a schema the running code does not expect.
set -e

case "${1:-serve}" in
  serve)
    exec node dist/main.js
    ;;
  migrate)
    # Forward-only, gated (docs/06 §6.2). The data source resolves its migration glob
    # relative to itself, so this finds dist/migrations/*.js inside the container.
    exec node node_modules/typeorm/cli.js -d dist/config/data-source.js migration:run
    ;;
  seed)
    # Staging only. It refuses to run against a database that already holds tenants, so a
    # re-deploy cannot duplicate the fixture data.
    exec node dist/seed.js
    ;;
  *)
    exec "$@"
    ;;
esac
