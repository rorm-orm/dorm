import models;

import core.thread;
import core.time;
import std.conv;
import std.datetime.date;
import std.datetime.systime;
import std.exception;
import std.range;
import std.stdio;

import dorm.api.db;
import dorm.declarative.conversion;

mixin SetupDormRuntime;

void main()
{
	auto appConfig = parseTomlConfig!BareConfiguration("database.toml");
	auto db = DormDB(appConfig.database);

	User.Fields userInsert1 = {
		name: "alice_alicington",
		fullName: "Alice Alicington",
		email: "alice@alicingt.on",
		auth: AuthInfo(
			"password",
			"12345678",
			"tok123",
			"secret",
			"???"
		)
	};

	User.Fields userInsert2 = {
		name: "bob_bobbington",
		fullName: "Bob Bobbington",
		email: "bob@bobbingt.on",
		auth: AuthInfo(
			"password",
			"12345678",
			"tok123",
			"secret",
			"???"
		)
	};

	User.Fields userInsert3 = {
		name: "foo_bar",
		fullName: "Foo Bar",
		email: "foo.bar@localhost",
		auth: AuthInfo(
			"password",
			"12345678",
			"tok123",
			"secret",
			"???"
		)
	};

	db.insert(userInsert1);
	assertThrown({
		// violating unique constraint here
		db.insert(userInsert1);
	}());
	db.insert(userInsert2);
	db.insert(userInsert3);

	User.Fields[] f = [userInsert1, userInsert2, userInsert3];

	size_t total;
	foreach (user; db.select!User.stream)
	{
		assert(user.fields == f[total]);
		total++;
	}

	assert(total == 3);

	db.update!User
		.set!`fields.banned`(true)
		.condition(u => u.name.equals(userInsert2.name))
		.await;

	userInsert3.fullName = "Baz Baz";

	db.update!User
		.set(userInsert3)
		.condition(u => u.name.equals(userInsert3.name))
		.await;

	userInsert2.banned = true;
	f = [userInsert1, userInsert2, userInsert3];
	total = 0;

	foreach (user; db.select!User.stream)
	{
		assert(user.fields == f[total]);
		total++;
	}

	assert(total == 3);

	assert(db.remove!User.all() == 3);

	foreach (user; db.select!User.stream)
		assert(false, "Deleted from " ~ DormLayout!User.tableName
			~ ", but found row " ~ user.fields.to!string);

	total = 0;
	db.insert(f[]);
	User toRemove;
	foreach (user; db.select!User.stream)
	{
		assert(user.fields == f[total]);
		if (total == 1)
			toRemove = user;
		total++;
	}

	assert(total == 3);

	assert(db.remove(toRemove));
	total = 0;
	f = [userInsert1, userInsert3];
	foreach (user; db.select!User.stream)
	{
		assert(user.fields == f[total]);
		if (total == 1)
			toRemove = user;
		total++;
	}

	assert(total == 2);

	auto nonExist = db.select!User.condition(u => u.name.like("nonexist%")).findOptional;
	assert(nonExist.isNull);
	auto optionalAlice = db.select!User.condition(u => u.name.like("alice%")).findOptional;
	assert(!optionalAlice.isNull);

	assertThrown(db.select!User.condition(u => u.name.like("nonexist%")).findOne);
	auto assumedFoobar = db.select!User.condition(u => u.name.like("foo%")).findOne;

	assert(db.remove!User.bulk(optionalAlice.get, assumedFoobar) == 2);

	assert(db.select!User.array.length == 0);

	writeln("all ok!");
}