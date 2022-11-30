import models;

import faked, std.datetime.systime, std.random, std.stdio;

import dorm.api.db;

mixin SetupDormRuntime;

void main()
{
	@DormPatch!User
	struct UserSelection
	{
		long id;
		string username;
		SysTime createdAt;
	}

	auto appConfig = parseTomlConfig!BareConfiguration("database.toml");
	auto db = DormDB(appConfig.database);

	auto f = new Faker_de(uniform!int);

	foreach (i; 0 .. 2)
	{
		@DormPatch!User
		struct UserInsert
		{
			string username;
			string password;
			bool isAdmin;
		}

		UserInsert user;
		user.username = f.nameName;
		user.password = "123456";
		db.insert(user);
	}

	auto oldestUsers = db.select!UserSelection
		.condition(u => u.not.isAdmin)
		.orderBy(u => u.createdAt.asc)
		.limit(5)
		.stream();

	writeln("Oldest 5 Users:");
	foreach (i, user; oldestUsers)
	{
		writefln!"#%d %s\tcreated at %s"(i + 1, user.username, user.createdAt);

		// delete first user
		if (i == 0)
			db.remove(user);
	}
}