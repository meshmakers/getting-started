admin = db.getSiblingDB("admin");

// Idempotent: on a re-run the user already exists and the localhost exception is closed,
// so createUser comes back as already-exists (51003), duplicate-key (11000) or
// Unauthorized (13). Treat those as "already seeded" and exit 0 instead of failing.
try {
    admin.createUser(
      {
        user: "octo-system-admin",
        pwd: "OctoAdmin1",
        roles: [ { role: "root", db: "admin" } ]
      });
} catch (e) {
    if (e.code === 51003 || e.code === 11000 || e.code === 13) {
        print('Admin user already present; skipping createUser.');
        quit(0);
    }
    throw e;
}
admin.auth("octo-system-admin", "OctoAdmin1");
