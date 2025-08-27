import models;

import core.thread;
import core.time;
import std.conv;
import std.datetime.date;
import std.datetime.systime;
import std.exception;
import std.range;
import std.stdio;
import std.typecons;

import dorm.api.db;
import dorm.declarative.conversion;
import dorm.types.relations;

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

	Toot toot = new Toot();
	toot.id = 1;
	toot.message = "Hello world!";
	toot.author = user;
	db.insert(toot);

	Toot toot2 = new Toot();
	toot2.id = 2;
	toot2.message = "Hello world!";
	toot2.author = user;
	toot2.dmTo = ModelRef!User(user2);
	db.insert(toot2);

	Comment.Fields comment;
	comment.replyTo = toot;
	comment.message = "Very cool!";
	comment.author.foreignKey = user.id;
	db.insert(comment);

	Comment.Fields comment2;
	comment2.replyTo = toot;
	comment2.message = "I like this";
	comment2.author.foreignKey = user2.id;
	db.insert(comment2);

	auto allToots = db.select!Toot
		.array;
	assert(allToots.length == 2);
	assert(allToots[0].dmTo.isNull);
	assert(!allToots[1].dmTo.isNull);
	assert(allToots[1].dmTo.get.foreignKey == user2.id);

	auto allComments = db.select!Comment
		.array;
	assert(allComments.length == 2);

	auto aliceComments = db.select!Comment
		.condition(c => c.author.email.like("alice%"))
		.array;
	assert(aliceComments.length == 1);

	Comment[] sortedComments = db.select!Comment
		.orderBy(c => c.author.email.asc)
		.populate(c => c.author.yes)
		.array;
	assert(sortedComments.length == 2);
	assert(sortedComments[0].author.populated.fullName == "Alice is cool");
	assert(sortedComments[1].author.populated.fullName == "Bob Bobbington");

	assert(!sortedComments[0].replyTo.isPopulated);
	assert(!sortedComments[1].replyTo.isPopulated);

	db.populate(sortedComments[0].replyTo);
	assert(sortedComments[0].replyTo.isPopulated);
	assert(sortedComments[0].replyTo.populated.message == "Hello world!");

	sortedComments[0].replyTo.clear();
	assert(!sortedComments[0].replyTo.isPopulated);

	db.populate([&sortedComments[0].replyTo, &sortedComments[1].replyTo]);

	assert(sortedComments[0].replyTo.isPopulated);
	assert(sortedComments[1].replyTo.isPopulated);
}