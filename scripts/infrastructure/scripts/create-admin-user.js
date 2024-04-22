admin = db.getSiblingDB("admin");
admin.createUser(
  {
    user: "octo-system-admin",
     pwd: "OctoAdmin1",
     roles: [ { role: "root", db: "admin" } ]
  });
admin.auth("octo-system-admin", "OctoAdmin1");
