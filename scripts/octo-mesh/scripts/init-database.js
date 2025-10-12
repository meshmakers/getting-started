var cfg = {
    "_id": "rs",
    "version": 1,
    "members": [
        {
            "_id": 0,
            "host": "octo-mongo-0.mongo:27017",
            "priority": 2
        },
        {
            "_id": 1,
            "host": "octo-mongo-1.mongo:27017",
            "priority": 0
        },
        {
            "_id": 2,
            "host": "octo-mongo-2.mongo:27017",
            "priority": 0
        }
    ]
};

rs.initiate(cfg, { force: true });
console.log('Waiting for replica set gets initialized!');
while(true)
{
    const status = rs.status();
    if (status.myState == 1)
    {
        console.log('Replica set fully initialized!');
        break;
    }
    sleep(2000);
}