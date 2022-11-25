import dorm.api.db;
import vibe.vibe;

import models;

mixin SetupDormRuntime;

// TODO: shared support
__gshared DormDB db;

void main()
{
	// TODO: parse this from database.toml
	DBConnectOptions options = {
		backend: DBBackend.SQLite,
		name: "database.sqlite3"
	};
	db = DormDB(options);

	logInfo("Database connection successful");

	/*
	// use @DormPatch structs instead of full models to only use column subsets
	db.insert(UserInsert(...));
	auto oldestUsers = db.select!UserQuery
		.condition(u => u.not.isAdmin)
		.orderBy(u => u.createdAt.asc)
		.limit(5)
		.stream();
	db.update!User
		.set!"username"("newUsername")
		.condition(u => u.username.equals("oldUsername"))
		.await;
	db.remove(myUserInstance);
	*/

	// db can now be used with the CRUD interface for example.
	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	auto listener = listenHTTP(settings, &hello);
	scope (exit)
		listener.stopListening();

	runApplication();
}

void hello(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("Hello, World!");
}
