import models;

import std.stdio;

import dorm.api.db;

mixin SetupDormRuntime;

void main()
{
	// TODO: parse this from database.toml
	DBConnectOptions options = {
		backend: DBBackend.SQLite,
		name: "database.sqlite3"
	};
	auto db = DormDB(options);

	// db can now be used with the CRUD interface for example.
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

	writeln("Hello dorm!");
}
