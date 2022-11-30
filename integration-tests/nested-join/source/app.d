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

	User user = new User();
	user.id = "bobbingnator1";
	user.fullName = "Bob Bobbington";
	user.email = "bob@bobbington.bob";
	db.insert(user);

	User user2 = new User();
	user2.id = "alicecool";
	user2.fullName = "Alice is cool";
	user2.email = "alice@alice.hq";
	db.insert(user2);

	Toot toot1 = new Toot();
	toot1.id = 1;
	toot1.message = "Hello world!";
	toot1.author = user;
	db.insert(toot1);

	Toot toot2 = new Toot();
	toot2.id = 2;
	toot2.message = "This is some toot";
	toot2.author = user2;
	db.insert(toot2);

	Reply reply = new Reply();
	reply.id = 0;
	reply.replyTo = toot1;
	reply.message = "Very cool!";
	db.insert(reply);

	Reply reply2 = new Reply();
	reply2.id = 1;
	reply2.replyTo = toot2;
	reply2.message = "I like this";
	db.insert(reply2);

	auto allComments = db.select!Reply
		.array;
	assert(allComments.length == 2);

	auto aliceComments = db.select!Reply
		.condition(c => c.replyTo.author.email.like("alice%"))
		.array;
	assert(aliceComments.length == 1);
}