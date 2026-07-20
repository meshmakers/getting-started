var cfg = {
    "_id": "rs",
    "version": 1,
    "members": [
        {
            "_id": 0,
            "host": "mongodb-0.mongodb.octo-infra.svc.cluster.local:27017",
            "priority": 1
        }
    ]
};

// Idempotent: only initiate on a fresh member. On a re-run against a persisted PVC the
// replica set is already configured and (once the admin user exists) the localhost
// exception is closed, so rs.initiate comes back as AlreadyInitialized (23) or
// Unauthorized (13). Either way the set is already up — skip and exit 0 so the caller
// sees success instead of a spurious error.
try {
    rs.initiate(cfg, { force: true });
} catch (e) {
    if (e.code === 23 /* AlreadyInitialized */ || e.code === 13 /* Unauthorized */) {
        print('Replica set already initialized; skipping rs.initiate.');
        quit(0);
    }
    throw e;
}

console.log('Waiting for replica set to initialize!');
while (true) {
    const status = rs.status();
    if (status.myState == 1) {
        console.log('Replica set fully initialized!');
        break;
    }
    sleep(2000);
}
